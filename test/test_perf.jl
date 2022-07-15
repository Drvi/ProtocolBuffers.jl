using JET
using ProtocolBuffers: Codecs
using .Codecs: vbyte_decode, vbyte_encode
using Test

macro test_noalloc(e) :(@test(@allocated($(esc(e))) == 0)) end

io = IOBuffer()

@test_opt vbyte_encode(io, typemax(UInt32))
@test_opt vbyte_encode(io, typemax(UInt64))
@test_opt vbyte_decode(io, UInt32)
@test_opt vbyte_decode(io, UInt64)

# to avoid compilation allocs
vbyte_encode(io, typemax(UInt32))
seekstart(io)
vbyte_decode(io, UInt32)
vbyte_encode(io, typemax(UInt64))
seekstart(io)
vbyte_decode(io, UInt64)

@test_noalloc vbyte_encode(io, typemax(UInt32))
seekstart(io)
@test @allocated(vbyte_decode(io, UInt32)) == 16
@test_noalloc vbyte_encode(io, typemax(UInt64))
seekstart(io)
@test @allocated(vbyte_decode(io, UInt64)) == 16