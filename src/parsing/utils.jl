function findfunc(namespace, i, name, from_innermost)
    n = length(namespace)
    if from_innermost
        i > n && return (string(namespace, '.', name), n) # first search
        j = something(findprev('.', namespace, i-1), 1)
        j == 1 && i == 1 && return ("", -1)               # not found
        j == 1 && i != 1 && return (namespace[1:i-1], 1)  # last search
        j != 1 && i != 1 && return (string(namespace[1:j], name), j)
    else
        i < 1 && return (name, 1)                                    # first search
        j = something(findnext('.', namespace, i+1), n)
        j == n && i == n && return ("", -1)                          # not found
        j == n && i != n && return (string(namespace, '.', name), n) # last search
        j != n && i != n && return (string(namespace[1:j], name), j)
    end
    throw(error("When from_innermost is `true`, i must be >= 1, when from_innermost is `false`, i must be <= length(namespace), got (from_innermost=$from_innermost, i=$i)"))
end

function reference_type(def, t::ReferencedType)
    isa(def, MessageType) ? MESSAGE :
    isa(def, EnumType)    ? ENUM    :
    isa(def, ServiceType) ? SERVICE :
    isa(def, RPCType)     ? RPC     :
    throw(error("Referenced type `$(t.name)` has unsupported type $(typeof(def))"))
end

_postprocess_reference!(external_references, type, definitions, namespace) = nothing
function _postprocess_reference!(external_references, type::ReferencedType, definitions, namespace)
    if !type.resolved
        # We're trying to resolve the reference within our current file
        # if we don't succeed, we'll try to resolve the reference among
        # other proto files later, duing codegen.
        i = type.resolve_from_innermost ? length(namespace) + 1 : 0
        while true
            (namespaced_name, i) = findfunc(namespace, i, type.name, type.resolve_from_innermost)
            @warn type.name (; i, namespaced_name)
            if i == -1
                push!(external_references, type.name)
                break
            end
            def = get(definitions, namespaced_name, nothing)
            if !isnothing(def)
                type.name = namespaced_name
                type.type_namespace = namespace[1:i-1]
                type.reference_type = reference_type(def, type)
                type.resolved = true
                break
            end
        end
    end
end

function _postprocess_field!(external_references, f::FieldType{ReferencedType}, definitions, namespace)
    _postprocess_reference!(external_references, f.type, definitions, namespace)
end
function _postprocess_field!(external_references, f::FieldType{MapType}, definitions, namespace)
    _postprocess_reference!(external_references, f.type.valuetype, definitions, namespace)
end
_postprocess_field!(external_references, f::FieldType, definitions, namespace) = nothing
function _postprocess_field!(external_references, f::OneOfType, definitions, namespace)
    for field in f.fields
        _postprocess_field!(external_references, field, definitions, namespace)
    end
    return nothing
end
function _postprocess_field!(external_references, f::GroupType, definitions, namespace)
    for field in f.type.fields
        _postprocess_field!(external_references, field, definitions, namespace)
    end
    return nothing
end

_postprocess_type!(external_references, t::EnumType, definitions) = nothing
function _postprocess_type!(external_references, t::ServiceType, definitions)
    for rpc in t.rpcs
        _postprocess_reference!(external_references, rpc.request_type, definitions, t.name)
        _postprocess_reference!(external_references, rpc.response_type, definitions, t.name)
    end
    return nothing
end
function _postprocess_type!(external_references, t::MessageType, definitions)
    for field in t.fields
        _postprocess_field!(external_references, field, definitions, t.name)
    end
    return nothing
end

function postprocess_types!(definitions::Dict{String, Union{MessageType, EnumType, ServiceType}})
    # Traverse all definitions and see which of those referenced are not defined
    # in this module. Create a list of these imported definitions so that we can ignore
    # them when doing the topological sort.
    external_references = Set{String}()
    for definition in values(definitions)
        _postprocess_type!(external_references, definition, definitions)
    end
    return external_references
end

get_type_name(::AbstractProtoNumericType) = nothing
get_type_name(t::ExtendType)     = string(t.type.name)  # TODO: handle Extensions
get_type_name(t::FieldType)      = get_type_name(t.type)
get_type_name(t::GroupType)      = t.name
get_type_name(t::ReferencedType) = t.name
get_type_name(t::MessageType)    = t.name
get_type_name(t::EnumType)       = t.name
get_type_name(t::ServiceType)    = t.name
get_type_name(::StringType)      = nothing
get_type_name(::BytesType)       = nothing
get_type_name(::MapType)         = nothing

function get_upstream_dependencies!(t::ServiceType, out)
    for rpc in t.rpcs
        push!(out, rpc.request_type.name)
        push!(out, rpc.response_type.name)
    end
    return nothing
end
function get_upstream_dependencies!(::EnumType, out)
    return nothing
end
function get_upstream_dependencies!(t::GroupType, out)
    get_upstream_dependencies!(t.type, out)
    return nothing
end
function get_upstream_dependencies!(t::MessageType, out)
    for field in t.fields
        _get_upstream_dependencies!(field, out)
    end
    return nothing
end
function get_upstream_dependencies!(t::ExtendType, out) # TODO: handle Extensions
    _get_upstream_dependencies!(t.type, out)
    foreach(field->_get_upstream_dependencies!(field, out), t.field_extensions)
    return nothing
end

function _get_upstream_dependencies!(t::ReferencedType, out)
    push!(out, t.name)
    return nothing
end
function _get_upstream_dependencies!(t::OneOfType, out)
    for field in t.fields
        _get_upstream_dependencies!(field, out)
    end
    return nothing
end
function _get_upstream_dependencies!(t::FieldType, out)
    name = get_type_name(t.type)
    name === nothing || push!(out, name)
    return nothing
end
function _get_upstream_dependencies!(t::GroupType, out)
    push!(out, t.name)
    get_upstream_dependencies!(t.type, out)
    return nothing
end
function _get_upstream_dependencies!(t::MessageType, out)
    push!(out, t.name) # TODO: Is this needed?
    for field in t.fields
        _get_upstream_dependencies!(field, out)
    end
    return nothing
end