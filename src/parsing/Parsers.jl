module Parsers

using ..Lexers: Lexers, Lexer, next_token, filepath
using ..Tokens: Tokens, kind, val
import ..ProtocolBuffers: _topological_sort, get_upstream_dependencies!

const MAX_FIELD_NUMBER = Int(typemax(UInt32) >> 3)

mutable struct ParserState
    l::Lexer
    isdone::Bool
    t::Tokens.Token
    nt::Tokens.Token
    nnt::Tokens.Token
    errored::Bool
    is_proto3::Bool
end

function readtoken(ps::ParserState)
    ps.isdone && (return ps.t)

    nnt = Lexers.next_token(ps.l)
    # Eat comments and whitespaces
    while (kind(nnt) == Tokens.COMMENT || kind(nnt) == Tokens.WHITESPACE)
        nnt = Lexers.next_token(ps.l)
    end

    ps.t = ps.nt
    ps.nt = ps.nnt
    ps.nnt = nnt
    ps.isdone = kind(ps.t) == Tokens.ENDMARKER
    return ps.t
end

function ParserState(l::Lexer)
    ps = ParserState(
        l,
        false,
        Tokens.Token(Tokens.UNINIT, Tokens.NO_ERROR, (0,0), (0,0), ""),
        Tokens.Token(Tokens.UNINIT, Tokens.NO_ERROR, (0,0), (0,0), ""),
        Tokens.Token(Tokens.UNINIT, Tokens.NO_ERROR, (0,0), (0,0), ""),
        false,
        false,
    )
    readtoken(ps)
    readtoken(ps)
    return ps
end
ParserState(input::Union{IO,String}) = ParserState(Lexer(input))

Tokens.kind(ps::ParserState) = kind(ps.t)
token(ps::ParserState) = ps.t
peektoken(ps::ParserState) = ps.nt
dpeektoken(ps::ParserState) = (ps.nt, ps.nnt)
peekkind(ps::ParserState) = kind(ps.nt)
dpeekkind(ps::ParserState) = (kind(ps.nt), kind(ps.nnt))

function expect(ps, k::Tokens.Kind)
    t = token(ps)
    if kind(ps) != k
        ps.errored = true
        throw(error("Found $(t) (value: `$(val(t))`), expected $(k) at $(t.startpos)"))
    end
    return token(ps)
end

function expectnext(ps, k::Tokens.Kind)
    t = peektoken(ps)
    if kind(t) != k
        ps.errored = true
        throw(error("Found $(t) (value: `$(val(t))`), expected $(k) at $(t.startpos)"))
    end
    return readtoken(ps)
end

function expectnext(ps, f::Function)
    t = peektoken(ps)
    if !f(kind(t))
        ps.errored = true
        throw(error("Found $(t) (value: `$(val(t))`), expected one of $(kind(t)) at $(t.startpos)"))
    end
    return readtoken(ps)
end

function accept(ps, f::Union{Function,Tokens.Kind,String})
    t = peektoken(ps)
    if isa(f, Function)
        ok = f(t)::Bool
    elseif isa(f, Tokens.Kind)
        ok = kind(t) == f
    else
        ok = val(t) == f
    end
    ok && readtoken(ps)
    return ok
end

function accept_batch(ps, f)
    ok = false
    while accept(ps, f)
        ok = true
    end
    return ok
end

function parse_integer_value(ps)
    nk, nnk = dpeekkind(ps)
    if nk == Tokens.DEC_INT_LIT
        return parse(Int, val(readtoken(ps)))
    elseif nk == Tokens.HEX_INT_LIT
        return parse(Int, val(readtoken(ps))[3:end]; base=16)
    elseif nk == Tokens.OCT_INT_LIT
        return parse(Int, val(readtoken(ps)); base=8)
    elseif nk == Tokens.PLUS && nnk == Tokens.DEC_INT_LIT
        readtoken(ps)
        parse(Int, val(readtoken(ps)))
    elseif nk == Tokens.MINUS && nnk == Tokens.DEC_INT_LIT
        readtoken(ps)
        parse(Int, string("-", val(readtoken(ps))))
    else
        error("Encountered invalid token sequence while parsing integer value: $(dpeektoken(ps))")
    end
end

include("proto_types.jl")

@enum(ImportOption, NONE, PUBLIC, WEAK)

struct ProtoImportedPackage
    import_option::ImportOption
    path::String
end

struct ProtoFilePreamble
    isproto3::Bool
    namespace::Vector{String}
    julia_namespace::Vector{String}
    options::Dict{String,Union{String,Dict{String}}}
    imports::Vector{ProtoImportedPackage}
end

function julia_namespace(namespace::Vector{<:AbstractString})
    isempty(namespace) && return namespace
    seen = Set{String}()
    n = 1
    out = Vector{String}(undef, length(namespace))
    for part in namespace
        module_name = string(replace(titlecase(part), "_" => ""), "PB")
        _module_name = module_name
        i = 1
        while _module_name in seen
            _module_name = string(module_name, string(i))
            i += 1
        end
        push!(seen, _module_name)
        out[n] = _module_name
        n += 1
    end
    return out
end

function check_name_collisions(packages, julia_packages, definitions, package_file, definitions_file)
    levels_to_check = length(packages) <= 1 ? @view(packages[1:length(packages)]) : @view(packages[[begin,end]])
    julia_levels_to_check = length(julia_packages) <= 1 ? @view(julia_packages[1:length(julia_packages)]) : @view(julia_packages[[begin,end]])
    collisions = intersect(levels_to_check, keys(definitions))
    append!(collisions, intersect(julia_levels_to_check, keys(definitions)))
    !isempty(collisions) &&
        throw(error(string(
            "Proto package `$(join(packages, '.'))` @ '$(package_file)' which would produce (nested) ",
            "Julia modules $(julia_packages), clashes with names of following top-level definitions $(string.(collisions))",
            package_file == definitions_file ? "" : " from '$(definitions_file)'"
        )))
end

struct ProtoFile
    filepath::String
    preamble::ProtoFilePreamble
    definitions::Dict{String,Union{MessageType, EnumType, ServiceType}}
    sorted_definitions::Vector{String}
    cyclic_definitions::Set{String}
    extends::Vector{ExtendType}
end

include("utils.jl")
include("proto_options.jl")

parse_proto_file(path::String) = parse_proto_file(ParserState(path))
function parse_proto_file(ps::ParserState)
    if accept(ps, Tokens.SYNTAX)
        expectnext(ps, Tokens.EQ)
        proto_version_string = val(expectnext(ps, Tokens.STRING_LIT))[2:end-1] # drop quotes
        @assert (proto_version_string in ("proto3", "proto2"))
        expectnext(ps, Tokens.SEMICOLON)
    else
        proto_version_string = "proto2"
    end
    ps.is_proto3 = proto_version_string == "proto3"

    definitions = Dict{String,Union{MessageType, EnumType, ServiceType}}()
    extends = ExtendType[]
    options = Dict{String,Union{String,Dict{String}}}()
    imported_packages = ProtoImportedPackage[]
    package_identifier = ""

    while !accept(ps, Tokens.ENDMARKER)
        if peekkind(ps) == Tokens.PACKAGE
            if !isempty(package_identifier)
                ps.errored = true
                error("Only a single package identifier permitted")
            end
            readtoken(ps)
            package_identifier = val(expectnext(ps, Tokens.IDENTIFIER))
            expectnext(ps, Tokens.SEMICOLON)
        elseif accept(ps, Tokens.OPTION)
            _parse_option!(ps, options)
            expectnext(ps, Tokens.SEMICOLON)
        elseif accept(ps, Tokens.IMPORT)
            import_option = accept(ps, Tokens.PUBLIC) ? PUBLIC : accept(ps, Tokens.WEAK) ? WEAK : NONE
            imported_package_name = val(expectnext(ps, Tokens.STRING_LIT))[2:end-1] # drop quotes
            push!(imported_packages, ProtoImportedPackage(import_option, imported_package_name))
            expectnext(ps, Tokens.SEMICOLON)
        elseif accept(ps, Tokens.EXTEND)
            # we collect top-level extends here
            # Scoped extends are extracted in find_external_references
            push!(extends, parse_extend_type(ps, definitions))
        else
            type = parse_type(ps, definitions)
            definitions[type.name] = type
        end
    end
    package_parts = split(package_identifier, '.', keepempty=false)
    julia_package_parts = julia_namespace(package_parts)
    preamble = ProtoFilePreamble(
        ps.is_proto3,
        package_parts,
        julia_package_parts,
        options,
        imported_packages,
    )
    check_name_collisions(package_parts, julia_package_parts, definitions, filepath(ps.l), filepath(ps.l))
    external_references = postprocess_types!(definitions, package_identifier)
    topologically_sorted, cyclic_definitions = _topological_sort(definitions, external_references)
    return ProtoFile(
        filepath(ps.l),
        preamble,
        definitions,
        topologically_sorted,
        cyclic_definitions,
        extends,
    )
end

end # module