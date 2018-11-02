"""
    rankfailures(dg)

Rank the failed packages in the given [`DependencyGraph`](@ref) `dg` by recursive benefit
to dependent packages if the package's test failures are fixed.
"""
function rankfailures(dg::DependencyGraph)
    out = Vector{Pair{Package,Int}}()
    for (i, pkg) in enumerage(dg.packages)
        dg.results[i] === failed || continue
        idx = indexin(dg, pkg)
        # Avoid cycles
        visited = BitSet()
        push!(visited, idx)
        stack = Int[idx]
        n = 0
        while !isempty(stack)
            x = pop!(stack)
            for y in inneighbors(dg, x)
                y in visited && continue
                push!(visited, y)
                push!(stack, y)
                n += 1
            end
        end
        push!(out, pkg => n)
    end
    sort!(out, by=last, rev=true)
end
