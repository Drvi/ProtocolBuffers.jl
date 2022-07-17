_max_varint_size(::Type{T}) where {T} = (sizeof(T) + (sizeof(T) >> 2))
_varint_size(x) = cld((8sizeof(x) - leading_zeros(x)), 7)
_varint_size(x::Int32) = x < 0 ? _varint_size(Int64(x)) : cld((8sizeof(x) - leading_zeros(x)), 7)
_varint_size1(x) = max(1, _varint_size(x))

# For scalars, we can't be sure about their size as they could be omitted completely
# (we're not sending default values over the wire), we only use them to size Dicts
__encoded_size(x::T) where {T<:Union{Int32,UInt32,Int64,UInt64,Enum}} = _varint_size1(x)
__encoded_size(x::T, ::Type{Val{:zigzag}}) where {T<:Union{Int32,UInt32,Int64,UInt64}} = _varint_size1(zigzag_encode(x))
__encoded_size(x::T) where {T<:Union{Bool,Float64,Float32}} = sizeof(x)
__encoded_size(x::String) = sizeof(x)
__encoded_size(x::T, ::Type{Val{:fixed}}) where {T<:Union{Int32,UInt32,Int64,UInt64}} = sizeof(x)

_encoded_size(xs::AbstractVector{T}) where {T<:Union{Int32,UInt32,Int64,UInt64,Enum}} = sum(_varint_size1, xs, init=0)
_encoded_size(xs::AbstractVector{T}, ::Type{Val{:zigzag}}) where {T<:Union{Int32,UInt32,Int64,UInt64}} = sum(x->_varint_size1(zigzag_encode(x)), xs, init=0)
_encoded_size(xs::AbstractVector{T}) where {T<:Union{UInt8,Bool,Float64,Float32}} = sizeof(xs)
_encoded_size(xs::AbstractVector{T}) where {T<:Union{String,AbstractVector{UInt8}}} = sum(sizeof, xs, init=0)
_encoded_size(xs::AbstractVector{T}, ::Type{Val{:fixed}}) where {T<:Union{Int32,UInt32,Int64,UInt64}} = sizeof(xs)

_encoded_size(d::Dict) = mapreduce(x->__encoded_size(x.first) + __encoded_size(x.second), +, d, init=0)
_encoded_size(d::Dict) = mapreduce(x->__encoded_size(x.first) + __encoded_size(x.second), +, d, init=0)

for T in (:(:fixed), :(:zigzag))
    @eval _encoded_size(d::Dict, ::Type{Val{Tuple{$(T),Nothing}}}) = mapreduce(x->__encoded_size(x.first, Val{$(T)}) + __encoded_size(x.second), +, d, init=0)
    @eval _encoded_size(d::Dict, ::Type{Val{Tuple{Nothing,$(T)}}}) = mapreduce(x->__encoded_size(x.first) + __encoded_size(x.second, Val{$(T)}), +, d, init=0)
end

for T in (:(:fixed), :(:zigzag)), S in (:(:fixed), :(:zigzag))
    @eval _encoded_size(d::Dict, ::Type{Val{Tuple{$(T),$(S)}}}) = mapreduce(x->__encoded_size(x.first, Val{$(S)}) + __encoded_size(x.second, Val{$(S)}), +, d, init=0)
end