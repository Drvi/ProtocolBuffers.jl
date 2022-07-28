using ProtocolBuffers
using ProtocolBuffers: _topological_sort
using ProtocolBuffers.CodeGenerators: ResolvedProtoFile
using ProtocolBuffers.CodeGenerators: Namespaces
using ProtocolBuffers.Parsers: parse_proto_file, ParserState
using ProtocolBuffers.Lexers: Lexer
using Test

function simple_namespace_from_protos(str::String, deps::Dict{String,String})
    l = Lexer(IOBuffer(str), "main")
    p = parse_proto_file(ParserState(l))
    r = ResolvedProtoFile("main", p)
    d = Dict{String, ResolvedProtoFile}("main" => r)
    for (k, v) in deps
        get!(d, k) do
            l = Lexer(IOBuffer(v), k)
            ResolvedProtoFile(k, parse_proto_file(ParserState(l)))
        end
    end
    d["main"] =  r
    sorted_files = _topological_sort(d, Set{String}())[1]
    sorted_files = [d[sorted_file] for sorted_file in sorted_files]
    n = Namespaces(sorted_files, "out")
    return d, n
end

@testset "Non-packaged proto imports packaged proto" begin
    d, n = simple_namespace_from_protos(
        "import \"path/to/a\";",
        Dict("path/to/a" => "package P;"),
    );
    @test length(n.non_package_protos) == 1
    @test n.non_package_protos[1].import_path == "main"
    @test length(n.packages) == 1
    @test haskey(n.packages, "P")
    @test n.packages["P"].ns.name == "P"
    @test n.packages["P"].ns.proto_files[1].import_path == "path/to/a"
end

@testset "Non-packaged proto imports packaged proto" begin
    d, n = simple_namespace_from_protos(
        "package P; import \"path/to/a\";",
        Dict("path/to/a" => ""),
    );
    @test length(n.non_package_protos) == 1
    @test n.non_package_protos[1].import_path == "path/to/a"
    @test length(n.packages) == 1
    @test haskey(n.packages, "P")
    @test n.packages["P"].ns.imports == Set(["path/to/a"])
    @test n.packages["P"].ns.name == "P"
    @test n.packages["P"].ns.proto_files[1].import_path == "main"
end

@testset "Non-packaged proto imports non-packaged proto" begin
    d, n = simple_namespace_from_protos(
        "import \"path/to/a\";",
        Dict("path/to/a" => ""),
    );
    @test length(n.non_package_protos) == 2
    @test n.non_package_protos[1].import_path == "path/to/a"
    @test n.non_package_protos[2].import_path == "main"
    @test isempty(n.packages)
end

@testset "Packaged proto imports packaged proto" begin
    d, n = simple_namespace_from_protos(
        "package A.B; import \"path/to/a\";",
        Dict("path/to/a" => "package B.A;"),
    );
    @test isempty(n.non_package_protos)
    @test haskey(n.packages, "A")
    @test haskey(n.packages, "B")
    @test n.packages["A"].ns.name == "A"
    @test n.packages["A"].ns.imports == Set(["path/to/a"])
    @test n.packages["A"].ns.submodules[1].name == "B"
    @test n.packages["A"].ns.submodules[1].proto_files[1].import_path == "main"
    @test n.packages["B"].ns.name == "B"
    @test n.packages["B"].ns.submodules[1].name == "A"
    @test n.packages["B"].ns.submodules[1].proto_files[1].import_path == "path/to/a"
end

@testset "External imports are imported in the first submodule that needs it" begin
    d, n = simple_namespace_from_protos(
        "package A.B.C.D.E; import \"path/to/a\"; import \"path/to/b\";",
        Dict(
            "main2" => "package A.B.C; import \"path/to/a\";",
            "path/to/a" => "package B.A;",
            "path/to/b" => "package B.A;",
        )
    );
    @test n.packages["A"].ns.submodules[1].imports == Set(["path/to/a"])
    @test n.packages["A"].ns.submodules[1].submodules[1].imports == Set{String}()
    @test n.packages["A"].ns.submodules[1].submodules[1].submodules[1].imports == Set(["path/to/b"])
    @test n.packages["A"].ns.submodules[1].submodules[1].submodules[1].submodules[1].imports == Set{String}()
end