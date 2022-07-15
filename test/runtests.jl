using Aqua
using JET
using ProtocolBuffers
using Test

include("unittests.jl")

@testset "JET" begin
    include("jet_test_utils.jl")
    jet_test_package(ProtocolBuffers)
    # jet_test_file("unittests.jl", ignored_modules=(JET.AnyFrameModule(Test),))
    include("test_perf.jl")
end

@testset "Aqua" begin
    Aqua.test_all(ProtocolBuffers)
end