using ProtocolBuffers
using ProtocolBuffers: _topological_sort
using ProtocolBuffers.CodeGenerators: ResolvedProtoFile
using ProtocolBuffers.CodeGenerators: Options
using ProtocolBuffers.CodeGenerators: Namespaces
using ProtocolBuffers.CodeGenerators: generate_module_file
using ProtocolBuffers.Parsers: parse_proto_file, ParserState
using ProtocolBuffers.Lexers: Lexer
using Test

function simple_namespace_from_protos(str::String, deps::Dict{String,String}=Dict{String, String}(), pkg::String="", options::Options=Options())
    l = Lexer(IOBuffer(str), "main")
    p = parse_proto_file(ParserState(l))
    r = ResolvedProtoFile("main", p)
    d = Dict{String, ResolvedProtoFile}("main" => r)
    io = IOBuffer()
    for (k, v) in deps
        get!(d, k) do
            l = Lexer(IOBuffer(v), k)
            ResolvedProtoFile(k, parse_proto_file(ParserState(l)))
        end
    end
    d["main"] =  r
    sorted_files = _topological_sort(d, Set{String}())[1]
    sorted_files = [d[sorted_file] for sorted_file in sorted_files]
    n = Namespaces(sorted_files, "out", d)
    !isempty(pkg) && generate_module_file(io, n.packages[pkg], "out", d, options, 1)
    return String(take!(io)), d, n
end

@testset "Non-packaged proto imports packaged proto" begin
    s, d, n = simple_namespace_from_protos(
        "import \"path/to/a\";",
        Dict("path/to/a" => "package P;"),
    );
    @test length(n.non_namespaced_protos) == 1
    @test n.non_namespaced_protos[1].import_path == "main"
    @test length(n.packages) == 1
    @test haskey(n.packages, "P")
    @test n.packages["P"].name == "PPB"
    @test n.packages["P"].dirname == "P"
    @test n.packages["P"].proto_files[1].import_path == "path/to/a"
end

@testset "Non-packaged proto imports packaged proto" begin
    s, d, n = simple_namespace_from_protos(
        "package P; import \"path/to/a\";",
        Dict("path/to/a" => ""),
    );
    @test length(n.non_namespaced_protos) == 1
    @test n.non_namespaced_protos[1].import_path == "path/to/a"
    @test length(n.packages) == 1
    @test haskey(n.packages, "P")
    @test n.packages["P"].nonpkg_imports == Set(["a_pb"])
    @test n.packages["P"].dirname == "P"
    @test n.packages["P"].proto_files[1].import_path == "main"
end

@testset "Non-packaged proto imports non-packaged proto" begin
    s, d, n = simple_namespace_from_protos(
        "import \"path/to/a\";",
        Dict("path/to/a" => ""),
    );
    @test length(n.non_namespaced_protos) == 2
    @test n.non_namespaced_protos[1].import_path == "path/to/a"
    @test n.non_namespaced_protos[2].import_path == "main"
    @test isempty(n.packages)
end

@testset "Packaged proto imports packaged proto" begin
    s, d, n = simple_namespace_from_protos(
        "package A.B; import \"path/to/a\";",
        Dict("path/to/a" => "package B.A;"),
    );
    @test isempty(n.non_namespaced_protos)
    @test haskey(n.packages, "A")
    @test haskey(n.packages, "B")
    @test n.packages["A"].dirname == "A"
    @test n.packages["A"].name == "APB"
    @test isempty(n.packages["A"].nonpkg_imports)
    @test n.packages["A"].external_imports == Set([joinpath("..", "B", "BPB.jl")])
    @test n.packages["A"].submodules[1].dirname == "B"
    @test n.packages["A"].submodules[1].name == "BPB"
    @test n.packages["A"].submodules[1].proto_files[1].import_path == "main"
    @test n.packages["B"].dirname == "B"
    @test n.packages["B"].name == "BPB"
    @test n.packages["B"].submodules[1].dirname == "A"
    @test n.packages["B"].submodules[1].name == "APB"
    @test n.packages["B"].submodules[1].proto_files[1].import_path == "path/to/a"
end

@testset "External dependencies are imported in in the topmost module where all downstreams can reach it" begin
    s, d, n = simple_namespace_from_protos(
        "package A.B.C.D.E; import \"path/to/a\"; import \"path/to/b\";",
        Dict(
            "main2" => "package A.B.C; import \"path/to/a\";",
            "path/to/a" => "package B.A;",
            "path/to/b" => "package B.A;",
        ),
        "A"
    );
    @test n.packages["A"].external_imports == Set([joinpath("..", "B", "BPB.jl")])
    @test n.packages["A"].submodules[1].external_imports == Set{String}()
    @test n.packages["A"].submodules[1].submodules[1].external_imports == Set(["...BPB"])
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].external_imports == Set{String}()
    @test s == """
    module APB

    include($(repr(joinpath("..", "B", "BPB.jl"))))

    include($(repr(joinpath("B", "BPB.jl"))))

    end # module APB
    """

    s, d, n = simple_namespace_from_protos(
        "package A.B.C.D.E; import \"path/to/a\"; import \"path/to/b\";",
        Dict(
            "main2" => "package A.B.C; import \"path/to/a\";",
            "path/to/a" => "",
            "path/to/b" => "",
        ),
        "A"
    );
    @test n.packages["A"].nonpkg_imports == Set(["a_pb", "b_pb"])
    @test n.packages["A"].submodules[1].submodules[1].external_imports == Set(["...a_pb"])
    @test s == """
    module APB

    include($(repr(joinpath("..", "a_pb.jl"))))
    include($(repr(joinpath("..", "b_pb.jl"))))

    include($(repr(joinpath("B", "BPB.jl"))))

    end # module APB
    """
end

@testset "Imported non-namespaced protos are put in artificial modules internally" begin
    s, d, n = simple_namespace_from_protos(
        "package A.B.C.D.E; import \"path/to/a\"; import \"path/to/b\";",
        Dict(
            "main2" => "package A.B.C; import \"path/to/a\";",
            "path/to/a" => "",
            "path/to/b" => "",
        ),
        "A",
        Options(always_use_modules=false)
    );
    @test n.packages["A"].nonpkg_imports == Set(["a_pb", "b_pb"])
    @test n.packages["A"].submodules[1].submodules[1].external_imports == Set(["...a_pb"])
    @test s == """
    module APB

    module a_pb
        include($(repr(joinpath("..", "a_pb.jl"))))
    end
    module b_pb
        include($(repr(joinpath("..", "b_pb.jl"))))
    end

    include($(repr(joinpath("B", "BPB.jl"))))

    end # module APB
    """
end

@testset "Repeated julia module names are made unique" begin
    s, d, n = simple_namespace_from_protos(
        "package A.B.A.D.B.A;",
    );
    @test haskey(n.packages, "A")
    @test n.packages["A"].name == "APB"
    @test n.packages["A"].dirname == "A"
    @test n.packages["A"].submodules[1].name == "BPB"
    @test n.packages["A"].submodules[1].dirname == "B"
    @test n.packages["A"].submodules[1].submodules[1].name == "APB1"
    @test n.packages["A"].submodules[1].submodules[1].dirname == "A"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].name == "DPB"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].dirname == "D"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].name == "BPB1"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].dirname == "B"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].submodules[1].name == "APB2"
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].submodules[1].dirname == "A"
end

@testset "Relative internal imports" begin
    s, d, n = simple_namespace_from_protos(
        "package A.B.C.D.E; import \"main2\";",
        Dict(
            "main2" => "package A.B.C.D;",
        ),
        "A",
    );
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].internal_imports == Set([".....APB"])

    s, d, n = simple_namespace_from_protos(
        "package A.B.C.D.E.F; import \"main2\";",
        Dict(
            "main2" => "package A.B.C.D;",
        ),
        "A",
    );
    @test n.packages["A"].submodules[1].submodules[1].submodules[1].submodules[1].submodules[1].internal_imports == Set(["......APB"])

    s, d, n = simple_namespace_from_protos(
        "package A.B.C; import \"main2\";",
        Dict(
            "main2" => "package A.B.C.D;",
        ),
        "A",
    );
    @test n.packages["A"].submodules[1].submodules[1].internal_imports == Set(["...APB"])

    s, d, n = simple_namespace_from_protos(
        "package A.B; import \"main2\";",
        Dict(
            "main2" => "package A.B.C.D;",
        ),
        "A",
    );
    @test n.packages["A"].submodules[1].internal_imports == Set(["..APB"])
    @test n.packages["A"].submodules[1].name == "BPB"
end