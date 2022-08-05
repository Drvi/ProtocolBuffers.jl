
function _parse_identifier_with_url(ps)
    ident = expectnext(ps, Tokens.IDENTIFIER)
    if accept(ps, Tokens.FORWARD_SLASH)
        ident = string(ident, "/", expectnext(ps, Tokens.IDENTIFIER))
    end
    return ident
end


function _parse_option_value(ps) # TODO: proper value parsing with validation
    accept(ps, Tokens.PLUS)
    has_minus = accept(ps, Tokens.MINUS)
    nk, nnk = dpeekkind(ps)
    str_val = val(readtoken(ps))
    # C-style string literals spanning multiple lines
    if nk == Tokens.STRING_LIT && nnk == Tokens.STRING_LIT
        while peekkind(ps) == Tokens.STRING_LIT
            str_val = string(@view(str_val[begin:end-1]), val(readtoken(ps)))
        end
    end
    return has_minus ? string("-", str_val) : str_val
end

function _parse_option_name(ps)
    option_name = ""
    last_name_part = ""
    prev_had_parens = false
    while true
        if accept(ps, Tokens.LPAREN)
            option_name *= string("(", _parse_identifier_with_url(ps), ")")
            expectnext(ps, Tokens.RPAREN)
            prev_had_parens = true
        elseif accept(ps, Tokens.LBRACKET)
            option_name *= string("[", _parse_identifier_with_url(ps), "]")
            expectnext(ps, Tokens.RBRACKET)
        elseif accept(ps, Tokens.IDENTIFIER)
            last_name_part = val(token(ps))
            if prev_had_parens
                startswith(last_name_part, '.') || error("Invalid option identifier $(option_name)$(last_name_part)")
            end
            option_name *= last_name_part
        elseif accept(ps, Tokens.DOT)
            expectnext(ps, Tokens.LPAREN)
            option_name *= string(".(", _parse_identifier_with_url(ps), ")")
            expectnext(ps, Tokens.RPAREN)
            prev_had_parens = true
        else
            break
        end
    end
    return option_name
end

function _parse_aggregate_option(ps)
    # TODO: properly validate that `option (complex_opt2).waldo = { waldo: 212 }` doesn't happen
    #       `option (complex_opt2) = { waldo: 212 }` ok
    #       `option (complex_opt2).waldo = 212 ` ok
    option_value_dict = Dict{String,Union{Dict,String}}()
    while !accept(ps, Tokens.RBRACE)
        option_name = _parse_option_name(ps)
        accept(ps, Tokens.COLON)
        if accept(ps, Tokens.LBRACE)
            option_value_dict[option_name] = _parse_aggregate_option(ps)
        else
            option_value_dict[option_name] = _parse_option_value(ps)
        end
        accept(ps, Tokens.COMMA)
    end
    return option_value_dict
end

# We consumed a LBRACKET ([)
function parse_field_options!(ps::ParserState, options::Dict{String,Union{String,Dict{String}}})
    while true
        _parse_option!(ps, options)
        accept(ps, Tokens.COMMA) && continue
        accept(ps, Tokens.RBRACKET) && break
        error("Missing comma in option lists at $(ps.l.current_row):$(ps.l.current_col)")
    end
end

# We consumed OPTION
# NOTE: does not eat SEMICOLON
function _parse_option!(ps::ParserState, options::Dict{String,Union{String,Dict{String}}})
    option_name = _parse_option_name(ps)
    accept(ps, Tokens.COLON)
    expectnext(ps, Tokens.EQ)  # =
    if accept(ps, Tokens.LBRACE) # {key: val, ...}
        options[option_name] = _parse_aggregate_option(ps)
        # accept(ps, Tokens.SEMICOLON)
    else
        options[option_name] = _parse_option_value(ps)
    end
    return nothing
end