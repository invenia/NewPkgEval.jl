module NewPkgEval

using BinaryBuilder
using BinaryProvider
using DataStructures
using Dates
using LibGit2
using LightGraphs
using Pkg
using Pkg.TOML
using UUIDs

using BinaryBuilder: UserNSRunner, run_interactive
using BinaryProvider: unpack, verify

export
    DependencyGraph,
    Package,
    Registry,
    runall!,
    runtest

# Utility functions
depsdir() = joinpath(dirname(@__DIR__), "deps")
downloadsdir(name::String) = joinpath(depsdir(), "downloads", name)
juliapath(version::Union{VersionNumber,String}) = joinpath(depsdir(), "julia-$version")
logpath(version::Union{VersionNumber,String}) = joinpath(dirname(@__DIR__), "logs-$version")

# Skip these packages when testing all packages
const SKIP_LIST = [
    "AbstractAlgebra", # Hangs forever
    "ChangePrecision", # Hangs forever
    "Chunks", # Hangs forever
    "DiscretePredictors", # Hangs forever
    "DotOverloading",
    "DynamicalBilliards", # Hangs forever
    "Electron",
    "Embeddings",
    "GeoStatsDevTools",
    "HCubature",
    "IndexableBitVectors",
    "LatinHypercubeSampling", # Hangs forever
    "LazyCall", # deleted, hangs
    "LazyContext",
    "LinearLeastSquares", # Hangs forever
    "MeshCatMechanisms",
    "NumberedLines",
    "OrthogonalPolynomials", # Hangs forever
    "Parts", # Hangs forever
    "Rectangle", # Hangs forever
    "RecurUnroll", # deleted, hangs
    "RequirementVersions",
    "SLEEF", # Hangs forever
    "SequentialMonteCarlo",
    "SessionHacker",
    "TypedBools", # deleted, hangs
    "ValuedTuples",
    "ZippedArrays", # Hangs forever
]

# Blindly assume these packages are okay
const OK_LIST = [
    "BinDeps", # Not really ok, but packages may list it just as a fallback
    "Compat",
    "Homebrew",
    "InteractiveUtils", # We rely on LD_LIBRARY_PATH working for the moment
    "LinearAlgebra", # Takes too long
    "NamedTuples", # As requested by quinnj
    "WinRPM",
]

include("types.jl")     # Types used to represent packages and dependencies
include("run.jl")       # Run package tests
include("results.jl")   # Analysis of test results

end # module
