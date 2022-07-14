# https://github.com/golang/protobuf/issues/992#issuecomment-558718772
struct ResolvedProtoFile
    import_path::String
    proto_file::ProtoFile
end

Base.@kwdef struct Options
    always_use_modules::Bool = true
    force_required::Union{Nothing,Dict{String,Set{String}}} = nothing
    add_kwarg_constructors::Bool = false
end

proto_module_file_name(path::AbstractString) = string(proto_module_name(path), ".jl")
proto_module_file_path(path::AbstractString) = joinpath(dirname(path), proto_module_file_name(path))
proto_module_name(path::AbstractString) = string(replace(titlecase(basename(path)), r"[-_]" => "", ".Proto" => ""), "_PB")
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

struct NamespaceTrie
    scope::String
    proto_files::Vector{ResolvedProtoFile}
    children::Dict{String,NamespaceTrie}
end
NamespaceTrie(s::AbstractString) = NamespaceTrie(s, [], Dict())
NamespaceTrie() = NamespaceTrie("", [], Dict())

function insert!(node::NamespaceTrie, file::ResolvedProtoFile)
    if !is_namespaced(file)
        push!(node.proto_files, file)
        return nothing
    end
    for scope in split(namespace(file), '.')
        node = get!(node.children, scope, NamespaceTrie(scope))
    end
    push!(node.proto_files, file)
    return nothing
end

function NamespaceTrie(files::Union{AbstractVector,Base.ValueIterator})
    namespace = NamespaceTrie()
    for file in files
        insert!(namespace, file)
    end
    namespace
end

function NamespaceTrie(files::Union{AbstractVector,Base.ValueIterator}, s::AbstractString)
    namespace = NamespaceTrie(s)
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

function create_namespaced_packages(ns::NamespaceTrie, output_directory::AbstractString, parsed_files, options)
    path = joinpath(output_directory, ns.scope, "")
    if !isempty(ns.scope) # top level, not in a module
        current_module_path = proto_module_file_name(ns.scope)
        open(joinpath(path, current_module_path), "w") do io
            println(io, "module $(proto_module_name(ns.scope))")
            println(io)

            # load in imported proto files that live outside of this package
            external_dependencies = Set{String}(Iterators.flatten(Iterators.map(import_paths, ns.proto_files)))
            setdiff!(external_dependencies, map(x->x.import_path, ns.proto_files))
            seen_imports = Dict{String,Nothing}()
            for external_dependency in external_dependencies
                file = parsed_files[external_dependency]
                if is_namespaced(file)
                    import_pkg_name = namespaced_top_import(file)
                    get!(seen_imports, import_pkg_name) do
                        println(io, "include(", repr(relpath(namespaced_top_include(file), current_module_path)), ")")
                        println(io, "import $(import_pkg_name)")
                    end
                else
                    println(io, "include(", repr(namespaced_top_include(file)), ")")
                    options.always_use_modules && println(io, "module $(replace(proto_script_name(p), ".jl" => ""))")
                end
            end
            !isempty(external_dependencies) && println(io)

            # load in scopes nested in this namespace (the modules ending with `_PB`)
            for (child_file) in keys(ns.children)
                include_path = joinpath(child_file, proto_module_file_name(child_file))
                println(io, "include(", repr(include_path), ")")
                println(io, "import .$(proto_module_name(child_file))")
            end

            # load in imported proto files that are defined in this package (the files ending with `_pb.jl`)
            sorted_files, _ = _topological_sort(
                (file.import_path => file for file in ns.proto_files),
                setdiff(keys(parsed_files), map(x->x.import_path, ns.proto_files))
            )
            for file in sorted_files
                module_name = proto_script_name(file)
                println(io, "include(", repr(module_name), ")")
            end

            println(io)
            println(io, "end # module $(proto_module_name(ns.scope))")
        end
    end
    for p in ns.proto_files
        dst_path = joinpath(path, proto_script_name(p))
        CodeGenerators.translate(dst_path, p, parsed_files, options)
    end
    for (child_dir, child) in ns.children
        !isdir(joinpath(path, child_dir)) && mkdir(joinpath(path, child_dir))
        create_namespaced_packages(child, path, parsed_files, options)
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

function protojl(
    relative_paths::Union{<:AbstractString,<:AbstractVector{<:AbstractString}},
    search_directories::Union{<:AbstractString,<:AbstractVector{<:AbstractString},Nothing}=nothing,
    output_directory::Union{<:AbstractString,Nothing}=nothing;
    include_vendored_wellknown_types::Bool=true,
    always_use_modules::Bool=true,
    force_required::Union{Nothing,<:Dict{<:AbstractString,<:Set{<:AbstractString}}}=nothing,
    add_kwarg_constructors::Bool=false,
)
    if isnothing(search_directories)
        search_directories = ["."]
    elseif isa(search_directories, AbstractString)
        search_directories = [search_directories]
    end
    validate_search_directories!(search_directories, include_vendored_wellknown_types)

    if isa(relative_paths, AbstractString)
        relative_paths = [relative_paths]
    end
    absolute_paths = validate_proto_file_paths!(relative_paths, search_directories)

    parsed_files = Dict{String,ResolvedProtoFile}()
    _import_paths = Set{String}()
    for (rel_path, abs_path) in zip(relative_paths, absolute_paths)
        p = Parsers.parse_proto_file(abs_path)
        parsed_files[rel_path] = ResolvedProtoFile(rel_path, p)
        union!(_import_paths, import_paths(p))
    end
    resolve_imports!(_import_paths, parsed_files, search_directories)

    if isnothing(output_directory)
        output_directory = mktempdir(tempdir(); prefix="jl_proto_", cleanup=false)
        @info output_directory
    else
        isdir(output_directory) || error("`output_directory` \"$output_directory\" doesn't exist")
        output_directory = abspath(output_directory)
    end
    ns = NamespaceTrie(values(parsed_files))
    options = Options(always_use_modules, force_required, add_kwarg_constructors)
    create_namespaced_packages(ns, output_directory, parsed_files, options)
    return nothing
end
