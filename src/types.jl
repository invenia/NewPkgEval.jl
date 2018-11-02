"""
    Package

Type representing a single package with fields containing metadata about the package.

# Fields

* `name`: Name of the package
* `uuid`: UUID of the package
* `path`: Path to the package's TOML files
* `version`: Maximum available version of the package, or `nothing` for stdlib packages
* `registry`: Name of the registry containing the package, or `nothing` for stdlib packages
"""
struct Package
    name::String
    uuid::UUID
    path::String
    version::Union{VersionNumber,Nothing}
    registry::Union{String,Nothing}
end

Base.isequal(a::Package, b::Package) =
    all(f->isequal(getfield(a, f), getfield(b, f)), fieldnames(Package))
Base.:(==)(a::Package, b::Package) = isequal(a, b)

function Base.show(io::IO, pkg::Package)
    print(io, "Package \"", pkg.name, "\" (", pkg.uuid, "), version ")
    show(io, pkg.version)
    pkg.registry === nothing || print(io, ", in registry \"", pkg.registry, "\"")
    nothing
end

"""
    Registry

Type representing a Pkg registry with fields containing metadata about the registry.

# Fields

* `name`: Name of the registry
* `uuid`: UUID of the registry
* `path`: Path containing the registry's root directory
* `packages`: Vector of [`Package`](@ref)s in the registry

# Constructors

    Registry(path::String)

Create a `Registry` object given a path to a registry's root directory containing a
Registry.toml file.
"""
struct Registry
    name::String
    uuid::UUID
    path::String
    packages::Vector{Package}

    function Registry(path::String)
        regfile = joinpath(path, "Registry.toml")
        isfile(regfile) || throw(ArgumentError("Registry.toml not found in '$path'"))
        packages = Vector{Package}()
        reg = Pkg.Types.read_registry(regfile)
        for (uuid, pkginfo) in reg["packages"]
            pkgpath = joinpath(path, pkginfo["path"])
            allvers = Pkg.Operations.load_versions(pkgpath)
            ver = maximum(keys(allvers))
            push!(packages, Package(pkginfo["name"], UUID(uuid), pkgpath, ver, reg["name"]))
        end
        new(reg["name"], UUID(reg["uuid"]), path, packages)
    end
end

Base.show(io::IO, reg::Registry) =
    print(io, "Registry \"", reg.name, "\" (", reg.uuid, ") at ", reg.path,
          " containing ", length(reg.packages), " packages")

"""
    stdlibs() -> Dict{Package,Vector{Package}}

Construct a `Dict` containing all of Julia's stdlib packages as keys with vectors of their
respective dependencies as values.
"""
function stdlibs()
    packages = Dict{Package,Vector{Package}}()
    for name in readdir(Pkg.Types.stdlib_dir())
        path = Pkg.Types.stdlib_path(name)
        project = Pkg.Types.read_project(joinpath(path, "Project.toml"))
        deps = Vector{Package}()
        for (depname, depuuid) in project["deps"]
            dep = Package(depname, UUID(depuuid), Pkg.Types.stdlib_path(depname), nothing, nothing)
            push!(deps, dep)
        end
        packages[Package(name, UUID(project["uuid"]), path, nothing, nothing)] = deps
    end
    packages
end

"""
    TestResult

`Enum` type with instances describing outcomes for package tests.

# Values

* `untested`: Tests have not yet been run for this package
* `passed`: Tests passed
* `failed`: Tests failed
* `skipped`: This package has been skipped from testing
"""
@enum TestResult untested passed failed skipped
# TODO: Implement timedout

"""
    DependencyGraph

Type representing a directed graph of package dependencies.
"""
struct DependencyGraph
    vertex_map::Dict{UUID,Int}
    packages::Vector{Package}
    results::Vector{TestResult}
    graph::SimpleDiGraph
end

"""
    DependencyGraph(packages::Vector{Package})

Construct a package dependency graph based on the given packages. Standard library packages
are added to the list automatically.
"""
function DependencyGraph(packages::Vector{Package})
    pkgs = copy(packages)
    stds = stdlibs()
    for (std, _) in stds
        found = false
        for (i, pkg) in enumerate(pkgs)
            # Some registered packages share a name and UUID with a standard library package
            # and in those cases we want the standard library package instead, since the
            # registered one is almost surely outdated.
            if pkg.uuid == std.uuid && pkg.name == std.name
                pkgs[i] = std
                found = true
            end
            found && break
        end
        found || push!(pkgs, std)
    end
    vertex_map = Dict{UUID,Int}(pkg.uuid => i for (i, pkg) in enumerate(pkgs))
    graph = SimpleDiGraph(length(pkgs))
    for (std, deps) in stds, dep in deps
        add_edge!(graph, vertex_map[std.uuid], vertex_map[dep.uuid])
    end
    for pkg in pkgs
        haskey(stds, pkg) && continue
        data = Pkg.Operations.load_package_data(UUID, joinpath(pkg.path, "Deps.toml"), pkg.version)
        data === nothing && continue
        for (depname, depuuid) in data
            add_edge!(graph, vertex_map[pkg.uuid], vertex_map[depuuid])
        end
    end
    # Arbitrarily break dependency cycles
    for cycle in simplecycles(graph)
        rem_edge!(graph, last(cycle), first(cycle))
    end
    DependencyGraph(vertex_map, pkgs, fill(untested, length(pkgs)), graph)
end

"""
    DependencyGraph(registry::Registry)

Construct a dependency graph based on the packages in the given registry. Standard library
packages are added automatically.
"""
DependencyGraph(reg::Registry) = DependencyGraph(reg.packages)

# Kind of a pun, but meh
"""
    indexin(dg::DependencyGraph, package) -> Int

Find the index (i.e. vertex) of the given package in the dependency graph. The package
can be a [`Package`](@ref) or a `String` of the package's name.
"""
Base.indexin(dg::DependencyGraph, name::AbstractString) = findfirst(p->p.name == name, dg.packages)
Base.indexin(dg::DependencyGraph, pkg::Package) = indexin(dg, pkg.name)

"""
    getindex(dg::DependencyGraph, i::Integer) -> Tuple{Package,TestResult}

Retrieve the package and its test result at the given index (i.e. vertex) in the package
dependency graph.
"""
function Base.getindex(dg::DependencyGraph, i::Integer)
    @boundscheck checkbounds(dg.packages, i)
    @inbounds (dg.packages[i], dg.results[i])
end

LightGraphs.vertices(dg::DependencyGraph) = vertices(dg.graph)
LightGraphs.outneighbors(dg::DependencyGraph, v::Integer) = outneighbors(dg.graph, v)
LightGraphs.inneighbors(dg::DependencyGraph, v::Integer) = inneighbors(dg.graph, v)

"""
    skip!(dg::DependencyGraph, package)

Recursively mark the tests for the given package and for all packages that depend on it
as skipped. The package can be specified as an integer vertex in the graph or as a
[`Package`](@ref).
"""
function skip!(dg::DependencyGraph, idx::Integer)
    dg.results[idx] = skipped
    for revidx in inneighbors(dg, idx)
        dg.results[revidx] == skipped && continue
        skip!(dg, revidx)
    end
end

skip!(dg::DependencyGraph, pkg::Package) = skip!(dg, indexin(dg, pkg))
