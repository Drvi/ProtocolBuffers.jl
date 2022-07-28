# https://github.com/golang/protobuf/issues/992#issuecomment-558718772
proto_module_file_name(path::AbstractString) = string(proto_module_name(path), ".jl")
proto_module_file_path(path::AbstractString) = joinpath(dirname(path), proto_module_file_name(path))
proto_module_name(path::AbstractString) = string(replace(titlecase(basename(path)), r"[-_]" => "", ".Proto" => ""), "PB")
proto_module_path(path::AbstractString) = joinpath(dirname(path), proto_module_name(path))
proto_script_name(path::AbstractString) = string(replace(basename(path), ".proto" => ""), "_pb.jl")
proto_script_path(path::AbstractString) = joinpath(dirname(path), proto_script_name(path))
function namespaced_top_import(p::AbstractString)
    top = first(split(p, "."))
    return string('.', proto_module_name(top))
end

has_dependencies(p::ProtoFile) = !isempty(p.preamble.imports)
is_namespaced(p::ProtoFile) = !isempty(p.preamble.namespace)
namespace(p::ProtoFile) = p.preamble.namespace
namespaced_dirpath(p::ProtoFile) = replace(namespace(p), '.' => '/')
namespaced_path(p::ProtoFile) = joinpath(namespaced_dirpath(p), basename(p.filepath))
proto_module_file_name(p::ProtoFile) = proto_module_file_name(p.filepath)
proto_module_file_path(p::ProtoFile) = proto_module_file_path(p.filepath)
proto_module_name(p::ProtoFile) = proto_module_name(p.filepath)
proto_module_path(p::ProtoFile) = proto_module_path(p.filepath)
proto_script_name(p::ProtoFile) = proto_script_name(p.filepath)
proto_script_path(p::ProtoFile) = proto_script_path(p.filepath)
import_paths(p::ProtoFile) = (i.path for i in p.preamble.imports)
function namespaced_top_include(p::ProtoFile)
    top = first(split(namespace(p), "."))
    return joinpath(top, proto_module_file_name(top))
end
namespaced_top_import(p::ProtoFile) = namespaced_top_import(namespace(p))

has_dependencies(p::ResolvedProtoFile) = has_dependencies(p.proto_file)
is_namespaced(p::ResolvedProtoFile) = is_namespaced(p.proto_file)
namespace(p::ResolvedProtoFile) = namespace(p.proto_file)
namespaced_path(p::ResolvedProtoFile) = namespaced_path(p.proto_file)
namespaced_dirpath(p::ResolvedProtoFile) = namespaced_dirpath(p.proto_file)
proto_module_file_name(p::ResolvedProtoFile) = proto_module_file_name(p.proto_file)
proto_module_file_path(p::ResolvedProtoFile) = proto_module_file_path(p.proto_file)
proto_module_name(p::ResolvedProtoFile) = proto_module_name(p.proto_file)
proto_module_path(p::ResolvedProtoFile) = proto_module_path(p.proto_file)
proto_script_name(p::ResolvedProtoFile) = proto_script_name(p.proto_file)
proto_script_path(p::ResolvedProtoFile) = proto_script_path(p.proto_file)
import_paths(p::ResolvedProtoFile) = import_paths(p.proto_file)
namespaced_top_include(p::ResolvedProtoFile) = namespaced_top_include(p.proto_file)
namespaced_top_import(p::ResolvedProtoFile) = namespaced_top_import(p.proto_file)

struct Submodule
    name::String
    proto_files::Vector{ResolvedProtoFile} # Files defined at this package level
    submodules::Vector{Submodule}          # Inserted in topologically sorted order
    submodule_names::Vector{String}        # At every level, these have to be included so that there are no secluded parts of the package
    imports::Set{String}                   # Non-internal imports -- only populated on the top level
end
Submodule(s::AbstractString) = Submodule(s, [], [], [], Set())
Submodule() = Submodule("", [], [], [], Set())

struct ProtoPackage
    ns::Submodule
    root_path::String
end
ProtoPackage(name::AbstractString, root_path::AbstractString) = ProtoPackage(Submodule(name), root_path)

struct Namespaces
    non_package_protos::Vector{ResolvedProtoFile}
    packages::Dict{String,ProtoPackage}
end

function Namespaces(files_in_order::Vector{ResolvedProtoFile}, root_path::String)
    t = Namespaces([], Dict())
    internal_import_sets = Dict{String,Set{String}}()
    for file in files_in_order
        if !is_namespaced(file)
            push!(t.non_package_protos, file)
        else
            top_namespace = first(split(namespace(file), '.'))
            p = get!(t.packages, top_namespace, ProtoPackage(top_namespace, root_path))
            insert!(p.ns, file)
            push!(get!(internal_import_sets, top_namespace, Set{String}()), file.import_path)
        end
    end
    for (k, p) in t.packages
        internal_import_set = internal_import_sets[k]
        populate_imports!(p.ns, Set(file.import_path for file in files_in_order if !(file.import_path in internal_import_set)))
    end
    return t
end

function insert!(node::Submodule, file::ResolvedProtoFile)
    if !is_namespaced(file)
        push!(node.proto_files, file)
        return nothing
    end
    for name in split(namespace(file), '.')
        name == node.name && continue
        i = findfirst(==(name), node.submodule_names)
        if isnothing(i)
            push!(node.submodule_names, name)
            node = push!(node.submodules, Submodule(name))[end]
        else
            node = node.submodules[i]
        end
    end
    push!(node.proto_files, file)
    return nothing
end

function populate_imports!(node::Submodule, remaining::Set{String}, depth::Int=1)
    submodules = depth == 1 ? vcat(node, node.submodules) : node.submodules
    immediate_downstream_imports = (
        path
        for submodule in submodules
        for file in submodule.proto_files
        for path in import_paths(file)
    )
    for i in immediate_downstream_imports
        p = pop!(remaining, i, nothing)
        if !isnothing(p)
            push!(node.imports, i)
        end
    end
    for n in node.submodules
        populate_imports!(n, remaining, depth+1)
        # populate_imports!(n, copy(remaining))
    end
end

function Submodule(files::Vector{ResolvedProtoFile})
    namespace = Submodule()
    for file in files
        insert!(namespace, file)
    end
    namespace
end

function get_upstream_dependencies!(file::ResolvedProtoFile, upstreams)
    for path in import_paths(file)
        push!(upstreams, path)
    end
end

function get_dependencies(ns::Submodule, parsed_files::Dict)
    external_dependencies = Set{String}()
    internal_dependencies = Set{String}()
    isempty(ns.proto_files) && return external_dependencies, internal_dependencies
    top_namespace = namespaced_top_import(first(ns.proto_files))
    for p in ns.proto_files
        bot_namespace = split(namespace(p), '.')[end]
        for i in p.proto_file.preamble.imports
            imported_file = parsed_files[i.path]
            if top_namespace != namespaced_top_import(parsed_files[i.path])
                 # files don't share package root
                push!(external_dependencies, i.path)
            elseif bot_namespace != split(namespace(imported_file), '.')[end]
                # live in the same package, but in different leaf module
                push!(internal_dependencies, i.path)
            end
            # files live in the same module, no need to import
        end
    end
    return external_dependencies, internal_dependencies
end


function generate_submodule_file(io::IO, ns::Submodule, p::ProtoPackage, output_directory::AbstractString, parsed_files::Dict, options::Options, depth::Int)
    path = joinpath(output_directory, ns.name, "")
    println(io, "module $(proto_module_name(ns.name))")
    println(io)
    external_dependencies, internal_dependencies = get_dependencies(ns, parsed_files)
    has_deps = !isempty(external_dependencies) || !isempty(internal_dependencies) || !isempty(ns.imports)
    seen_imports = Dict{String,Nothing}()
    # This is where we **include** and import external dependencies so they are available downstream
    for external_import in ns.imports
        imported_file = parsed_files[external_import]
        import_pkg_name = namespaced_top_import(imported_file)
        get!(seen_imports, import_pkg_name) do
            println(io, "include(", repr(relpath(joinpath(p.root_path, namespaced_top_include(imported_file)), path)), ")")
            println(io, "import $(import_pkg_name)")
        end
    end
    # This is where we **import** external dependencies which were included somewhere in parent scope
    for external_dependency in external_dependencies
        file = parsed_files[external_dependency]
        if is_namespaced(file)
            import_pkg_name = namespaced_top_import(file)
            get!(seen_imports, import_pkg_name) do
                println(io, "import .$(import_pkg_name)")
            end
        else
            println(io, "include(", repr(namespaced_top_include(file)), ")")
            options.always_use_modules && println(io, "import .$(replace(proto_script_name(file), ".jl" => ""))")
        end
    end
    # This is where we import internal dependencies
    for internal_dependency in internal_dependencies
        file = parsed_files[internal_dependency]
        println(io, "import ..", proto_module_name(file))
    end
    has_deps && println(io)

    # load in names nested in this namespace (the modules ending with `PB`)
    for submodule_name in ns.submodule_names
        include_path = joinpath(submodule_name, proto_module_file_name(submodule_name))
        println(io, "include(", repr(include_path), ")")
        println(io, "import .$(proto_module_name(submodule_name))")
    end
    # load in imported proto files that are defined in this package (the files ending with `_pb.jl`)
    for file in ns.proto_files
        module_name = proto_script_name(file)
        println(io, "include(", repr(module_name), ")")
    end

    println(io)
    println(io, "end # module $(proto_module_name(ns.name))")
end

function create_namespaced_package(ns::Submodule, p::ProtoPackage, output_directory::AbstractString, parsed_files::Dict, options::Options, depth=1)
    path = joinpath(output_directory, ns.name, "")
    !isdir(path) && mkdir(path)
    current_module_path = proto_module_file_name(ns.name)
    open(joinpath(path, current_module_path), "w", lock=false) do io
        generate_submodule_file(io, ns, p, output_directory, parsed_files, options, depth)
    end
    for file in ns.proto_files
        dst_path = joinpath(path, proto_script_name(file))
        CodeGenerators.translate(dst_path, file, parsed_files, options)
    end
    for submodule in ns.submodules
        create_namespaced_package(submodule, p, path, parsed_files, options, depth+1)
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
