# # https://github.com/golang/protobuf/issues/992#issuecomment-558718772
proto_module_file_name(path::AbstractString) = string(proto_module_name(path), ".jl")
proto_module_name(path::AbstractString) = string(replace(titlecase(basename(path)), r"[-_]" => "", ".Proto" => ""), "PB")
proto_script_name(path::AbstractString) = string(replace(basename(path), ".proto" => ""), "_pb.jl")
proto_script_path(path::AbstractString) = joinpath(dirname(path), proto_script_name(path))
function namespaced_top_import(p::AbstractString)
    top = first(split(p, "."))
    return string('.', proto_module_name(top))
end

is_namespaced(p::ProtoFile) = !isempty(p.preamble.namespace)
namespace(p::ProtoFile) = p.preamble.namespace
proto_module_file_name(p::ProtoFile) = proto_module_file_name(p.filepath)
proto_module_name(p::ProtoFile) = proto_module_name(p.filepath)
proto_script_name(p::ProtoFile) = proto_script_name(p.filepath)
proto_script_path(p::ProtoFile) = proto_script_path(p.filepath)
import_paths(p::ProtoFile) = (i.path for i in p.preamble.imports)
function namespaced_top_include(p::ProtoFile)
    if is_namespaced(p)
        top = first(split(namespace(p), "."))
        return joinpath(top, proto_module_file_name(top))
    else
        return proto_script_name(p)
    end
end
namespaced_top_import(p::ProtoFile) = namespaced_top_import(namespace(p))

is_namespaced(p::ResolvedProtoFile) = is_namespaced(p.proto_file)
namespace(p::ResolvedProtoFile) = namespace(p.proto_file)
proto_module_file_name(p::ResolvedProtoFile) = proto_module_file_name(p.proto_file)
proto_module_name(p::ResolvedProtoFile) = proto_module_name(p.proto_file)
proto_script_name(p::ResolvedProtoFile) = proto_script_name(p.proto_file)
import_paths(p::ResolvedProtoFile) = import_paths(p.proto_file)
namespaced_top_include(p::ResolvedProtoFile) = namespaced_top_include(p.proto_file)
namespaced_top_import(p::ResolvedProtoFile) = namespaced_top_import(p.proto_file)
proto_script_path(p::ResolvedProtoFile) = proto_script_path(p.proto_file)

proto_package_name(p) = proto_module_name(first(split(namespace(p), '.')))
rel_import_path(file, root_path) = relpath(joinpath(root_path, "..", namespaced_top_include(file)), joinpath(root_path))


function internal_module_relative_import_path(importer, importee)
    importer_modules = split(importer, '.')
    importee_modules = split(importee, '.')
    n = length(importer_modules)
    m = length(importee_modules)
    # Must have common root and not importing itself
    @assert importer_modules[1] == importee_modules[1] && importer !== importee
    io = IOBuffer()
    # Eat the common part of the path
    i = 1 + count(p->p[1]==p[2], zip(importer_modules, importee_modules))
    # Ascend from the importer to the closest common ancestor
    foreach(_->print(io, '.'), i:n)
    # Descend from the common anscestor to the importee
    foreach(j->print(io, '.', proto_module_name(importee_modules[j])), i-(n>m):m)
    return String(take!(io))
end

struct ProtoModule
    name::String
    dirname::String
    proto_files::Vector{ResolvedProtoFile}
    submodules::Vector{ProtoModule} # Inserted in topologically sorted order
    submodule_names::Vector{String}
    internal_imports::Set{String}
    external_imports::Set{String}
    nonpkg_imports::Set{String}
end
empty_module(name::AbstractString, dirname::AbstractString) = ProtoModule(name, dirname, [], [], [], Set(), Set(), Set())

struct Namespaces
    non_namespaced_protos::Vector{ResolvedProtoFile}
    packages::Dict{String,ProtoModule}
end

function Namespaces(files_in_order::Vector{ResolvedProtoFile}, root_path::String, proto_files::Dict)
    t = Namespaces([], Dict())
    for file in files_in_order
        if !is_namespaced(file)
            push!(t.non_namespaced_protos, file)
        else
            top_namespace = first(split(namespace(file), '.'))
            module_name = proto_module_name(top_namespace)
            p = get!(t.packages, top_namespace, empty_module(module_name, top_namespace))
            add_file_to_package!(p, file, proto_files, root_path)
        end
    end
    return t
end

function add_file_to_package!(root::ProtoModule, file::ResolvedProtoFile, proto_files::Dict, root_path::String)
    node = root
    depth = 0
    for name in split(namespace(file), '.')
        module_name = proto_module_name(name)
        depth += 1
        module_name == node.name && continue
        i = findfirst(==(name), node.submodule_names)
        if isnothing(i)
            push!(node.submodule_names, name)
            node = push!(node.submodules, empty_module(module_name, name))[end]
        else
            node = node.submodules[i]
        end
    end
    for ipath in import_paths(file)
        imported_file = proto_files[ipath]
        if !is_namespaced(imported_file)
            # We always wrap the non-namespaced imports into modules internally
            # Sometimes they are forced to be namespaced with `always_use_modules`
            # but it is the responsibility of the root module to make sure there
            # is a importable module in to topmost scope
            depth != 1 && push!(node.external_imports, string("." ^ depth, replace(proto_script_name(imported_file), ".jl" => "")))
            push!(root.nonpkg_imports, replace(proto_script_name(imported_file), ".jl" => ""))
        else
            file_pkg = proto_package_name(imported_file)
            if namespace(file) == namespace(imported_file)
                continue # no need to import from the same package
            elseif file_pkg == root.name
                push!(node.internal_imports, internal_module_relative_import_path(namespace(file), namespace(imported_file)))
            else
                depth != 1 && push!(node.external_imports, string("." ^ depth, proto_package_name(imported_file)))
                push!(root.external_imports, rel_import_path(imported_file, root_path))
            end
        end
    end
    push!(node.proto_files, file)
    return nothing
end

function generate_module_file(io::IO, m::ProtoModule, output_directory::AbstractString, parsed_files::Dict, options::Options, depth::Int)
    println(io, "module $(m.name)")
    println(io)
    has_deps = !isempty(m.internal_imports) || !isempty(m.external_imports) || !isempty(m.nonpkg_imports)
    if depth == 1
        # This is where we include external packages so they are available downstream
        for external_import in m.external_imports
            println(io, "include(", repr(external_import), ')')
        end
        # This is where we include external dependencies that may not be packages.
        # We wrap them in a module to make sure that multiple downstream dependencies
        # can import them safely.
        for nonpkg_import in m.nonpkg_imports
            !options.always_use_modules && print(io, "module $(nonpkg_import)\n    ")
            println(io, "include(", repr(joinpath("..", string(nonpkg_import, ".jl"))), ')')
            !options.always_use_modules && println(io, "end")
        end
    else # depth > 1
        # We're not a top package module, we can import external dependencies
        # from the top package module.
        for external_import in m.external_imports
            println(io, "import ", external_import)
        end
    end
    # This is where we import internal dependencies
    for internal_import in m.internal_imports
        println(io, "import ", internal_import)
    end
    has_deps && println(io)

    # load in names nested in this namespace (the modules ending with `PB`)
    for submodule in m.submodules
        println(io, "include(", repr(joinpath(submodule.dirname, string(submodule.name, ".jl"))), ")")
    end
    # load in imported proto files that are defined in this package (the files ending with `_pb.jl`)
    for file in m.proto_files
        println(io, "include(", repr(proto_script_name(file)), ")")
    end
    println(io)
    println(io, "end # module $(m.name)")
end

function generate_package(node::ProtoModule, output_directory::AbstractString, parsed_files::Dict, options::Options, depth=1)
    path = joinpath(output_directory, node.dirname, "")
    !isdir(path) && mkdir(path)
    open(joinpath(path, string(node.name, ".jl")), "w", lock=false) do io
        generate_module_file(io, node, output_directory, parsed_files, options, depth)
    end
    for file in node.proto_files
        dst_path = joinpath(path, proto_script_name(file))
        CodeGenerators.translate(dst_path, file, parsed_files, options)
    end
    for submodule in node.submodules
        generate_package(submodule, path, parsed_files, options, depth+1)
    end
    return nothing
end

function validate_search_directories!(search_directories::Vector{String}, include_vendored_wellknown_types::Bool)
    include_vendored_wellknown_types && push!(search_directories, VENDORED_WELLKNOWN_TYPES_PARENT_PATH)
    unique!(map!(x->joinpath(abspath(x), ""), search_directories, search_directories))
    bad_dirs = filter(!isdir, search_directories)
    !isempty(bad_dirs) && error("`search_directories` $bad_dirs don't exist")
    return nothing
end

function validate_proto_file_paths!(relative_paths::Vector{<:AbstractString}, search_directories)
    @assert !isempty(relative_paths)
    unique!(map!(normpath, relative_paths, relative_paths))
    full_paths = copy(relative_paths)
    proto_files_not_within_reach = String[]
    abspaths = String[]
    for (i, proto_file_path) in enumerate(relative_paths)
        if startswith(proto_file_path, '/')
            push!(abspaths, proto_file_path)
            continue
        end
        found = false
        for search_directory in search_directories
            found && continue
            full_path = joinpath(search_directory, proto_file_path)
            if isfile(joinpath(search_directory, proto_file_path))
                found = true
                full_paths[i] = full_path
            end
        end
        !found && push!(proto_files_not_within_reach, proto_file_path)
    end
    !isempty(proto_files_not_within_reach) && error("Could not find following proto files: $proto_files_not_within_reach within $search_directories")
    !isempty(abspaths) && error("Paths to proto files must be relative to search_directories; got following absolute paths: $abspaths")
    return full_paths
end

function resolve_imports!(imported_paths::Set{String}, parsed_files, search_directories)
    missing_imports = String[]
    while !isempty(imported_paths)
        found = false
        path = pop!(imported_paths)
        path in keys(parsed_files) && continue
        for dir in search_directories
            found && continue
            full_path = joinpath(dir, path)
            if isfile(full_path)
                q = Parsers.parse_proto_file(full_path)
                parsed_files[path] = ResolvedProtoFile(path, q)
                union!(imported_paths, import_paths(q))
                found = true
            end
        end
        !found && push!(missing_imports, path)
    end
    !isempty(missing_imports) && error("Could not find following imports: $missing_imports within $search_directories")
    return nothing
end
