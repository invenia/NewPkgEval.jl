using NewPkgEval
using Test
using LightGraphs
using UUIDs

using NewPkgEval: TestResult, stdlibs, skip!, passed, failed, skipped, untested

@testset "Types" begin
    mktempdir() do d
        @test_throws ArgumentError Registry(d)
    end

    general_path = joinpath(first(DEPOT_PATH), "registries", "General")
    general = Registry(general_path)
    @test general isa Registry
    @test general.name == "General"
    @test general.uuid == UUID("23338594-aafe-5451-b93e-139f81909106")
    @test general.path == general_path
    @test length(general.packages) > 0

    let s = sprint(show, general)
        @test startswith(s, "Registry \"General\"")
        @test occursin(string(general.uuid), s)
        @test occursin(string(general.path), s)
        @test endswith(s, string("containing ", length(general.packages), " packages"))
    end

    example_ind = findfirst(p->p.name == "Example", general.packages)
    @test example_ind !== nothing
    example = general.packages[example_ind]
    @test example isa Package
    @test example.name == "Example"
    @test example.uuid == UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    @test example.path == joinpath(general_path, "E", "Example")
    @test example.version > v"0.0.0"
    @test example.registry == "General"

    let s = sprint(show, example)
        @test startswith(s, "Package \"Example\"")
        @test occursin(string(example.uuid), s)
        @test occursin(string(example.version), s)
        @test endswith(s, "in registry \"General\"")
    end

    @test length(instances(TestResult)) > 0

    stds = stdlibs()
    @test stds isa Dict{Package,Vector{Package}}
    @test any(p->p.name == "Test", keys(stds))
    linalg = let x = collect(keys(stds))
        x[findfirst(p->p.name == "LinearAlgebra", x)]
    end

    dg = DependencyGraph(general)
    @test dg isa DependencyGraph
    @test length(dg.packages) == length(dg.results) == length(keys(dg.vertex_map))
    @test all(==(untested), dg.results)
    @test length(vertices(dg)) >= length(general.packages)
    @test_throws BoundsError dg[-1]

    @test indexin(dg, "Super1337MemePackage420") === nothing
    linalg_ind = indexin(dg, "LinearAlgebra")
    @test linalg_ind !== nothing
    linalg_tup = dg[linalg_ind]
    @test linalg_tup isa Tuple{Package,TestResult}
    @test first(linalg_tup) == linalg
    @test isequal(first(linalg_tup), linalg)
    @test last(linalg_tup) === untested

    @test length(outneighbors(dg, linalg_ind)) == length(stds[linalg])
    @test length(inneighbors(dg, linalg_ind)) > 0

    # Skip by index
    skip!(dg, linalg_ind)
    @test dg[linalg_ind] == (linalg, skipped)
    @test all(==(skipped), dg.results[inneighbors(dg, linalg_ind)])

    # Skip by value
    fill!(dg.results, untested)
    skip!(dg, linalg)
    @test dg[linalg_ind] == (linalg, skipped)
    @test all(==(skipped), dg.results[inneighbors(dg, linalg_ind)])
end
