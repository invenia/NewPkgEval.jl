"""
    install_julia(version)

Download the specified version of Julia using the information provided in `Versions.toml`.
"""
function install_julia(version::VersionNumber)
    for (ver, data) in TOML.parsefile(joinpath(depsdir(), "Versions.toml"))
        VersionNumber(ver) == version || continue
        jlpath = juliapath(version)
        if haskey(data, "url")
            file = get(data, "file", "julia-$version.tar.gz")
            @assert !isabspath(file)
            download_verify_unpack(data["url"], data["sha"], jlpath;
                                   tarball_path=downloadsdir(file), force=true)
        else
            file = data["file"]
            isabspath(file) || (file = downloadsdir(file))
            verify(file, data["sha"])
            isdir(jlpath) || unpack(file, jlpath)
        end
        return
    end
    error("Requested Julia version $version not found")
end

"""
    runjulia(args=``; version=v"1.0", obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The keyword
argument `version` specifies the version of Julia to use, and `obtain` dictates whether
the specified version should first be downloaded. If `obtain` is `false`, it must
already be installed.
"""
function run_julia(args::Cmd=``; version=v"1.0", obtain=true, kwargs...)
    jldir = juliapath(version)
    if obtain
        install_julia(version)
    else
        @assert ispath(jldir)
    end
    jlpath = joinpath(jldir, first(readdir(jldir)))
    runner = UserNSRunner(pwd(), workspaces=[jlpath => "/maps/julia"])
    run_interactive(runner, `/maps/julia/bin/julia --color=yes $args`; kwargs...)
end

function runtest(pkg::Package; julia=v"1.0", depwarns=false, kwargs...)
    logdir = logpath(julia)
    isdir(logdir) || mkpath(logdir)
    c = quote
        mkpath("/root/.julia/registries")
        open("/etc/hosts", "w") do f
            println(f, "127.0.0.1\tlocalhost")
        end
        run(`mount -t devpts -o newinstance jrunpts /dev/pts`)
        run(`mount -o bind /dev/pts/ptmx /dev/ptmx`)
        run(`mount -t tmpfs tempfs /dev/shm`)
        Pkg.add($(pkg.name))
        Pkg.test($(pkg.name))
    end
    arg = "using Pkg; eval($(repr(c)))"
    try
        open(joinpath(logdir, pkg.name * ".log"), "w") do f
            run_julia(`$(depwarns ? "--depwarn=error" : "") -e $arg`;
                      version=julia, kwargs..., stdout=f, stderr=f)
        end
        return true
    catch
        return false
    end
end

function runall!(dg::DependencyGraph, ninstances::Int; julia=v"1.0", depwarns=false, kwargs...)
    install_julia(julia)

    frontier = BitSet()
    running = Vector{Union{Symbol,Nothing}}(nothing, ninstances)
    times = fill(now(), ninstances)
    processed = BitSet()
    cond = Condition()
    queue = binary_maxheap(Int)
    completed = Channel(Inf)

    for pkg in OK_LIST
        idx = indexin(dg, pkg)
        dg.results[idx] = passed
        put!(completed, idx)
    end

    for v in vertices(dg)
        isempty(outneighbors(dg, v)) || continue
        (dg.packages[v].name in SKIP_LIST || dg.results[v] !== untested) && continue
        push!(queue, v) # Schedule this package to run
    end

    for pkg in SKIP_LIST
        idx = indexin(dg, pkg)
        if idx === nothing
            @warn "Package $pkg in skip list but not found"
            continue
        end
        skip!(dg, idx)
    end

    done = processing = signaled = false
    workers = Vector{Task}()

    function stopwork!()
        if !done
            done = true
            notify(cond)
            put!(completed, -1)
            if !signaled
                for task in workers
                    (task == current_task() || istaskdone(task)) && continue
                    try
                        schedule(task, InterruptException(), error=true)
                    catch
                    end
                end
                signaled = true
            end
        end
    end

    @sync begin
        # Progress monitor
        @async begin
            try
                buf = IOBuffer()
                io = IOContext(buf, :color => true)
                while !isempty(queue) || !all(==(nothing), running) || isready(completed) || processing
                    showresult(io, dg, queue)
                    for i = 1:ninstances
                        r = running[i]
                        if r === nothing
                            println(io, "Worker ", i, ": -------")
                        else
                            println(io, "Worker ", i, ": ", r, " running for ",
                                    canonicalize(Dates.CompoundPeriod(now() - times[i])))
                        end
                    end
                    print(String(take!(buf)))
                    sleep(1)
                    print(io, CSI, instances + 1, "A", CSI, "1G", CSI, "0J")
                end
                stopwork!()
                println("done")
            catch err
                @error "Encountered error" exception=(err, stacktrace(catch_backtrace()))
                stopwork!()
                isa(err, InterruptException) || rethrow(err)
            end
        end

        # Scheduler
        @async begin
            try
                while !done
                    pkgno = take!(completed)
                    pkgno == -1 && break
                    processing = true
                    push!(processed, pkgno)
                    for revdep in inneighbors(dg, pkgno)
                        if dg.results[pkgno] !== passed
                            skip!(dg, revdep)
                        else
                            revdep in processed && continue
                            # Last dependency to finish adds it to the frontier
                            allprocessed = true
                            for dep in outneighbors(dg, revdep)
                                if !(dep in processed) || dg.results[dep] !== passed
                                    allprocessed = false
                                    break
                                end
                            end
                            allprocessed || continue
                            dg.results[revdep] === untested || continue
                            push!(queue, revdep)
                        end
                    end
                    notify(cond)
                    processing = false
                end
            catch err
                @error "Encountered error" exception=(err, stacktrace(catch_backtrace()))
                stopwork!()
                isa(err, InterruptException) || rethrow(err)
            end
        end

        # Workers
        for i = 1:ninstances
            push!(workers, @async begin
                try
                    while !done
                        if isempty(queue)
                            wait(cond)
                            continue
                        end
                        pkgno = pop!(queue)
                        pkg = dg.packages[pkgno]
                        running[i] = Symbol(pkg.name)
                        times[i] = now()
                        didpass = runtest(pkg, version=version, obtain=false, depwarns=depwarns)
                        dg.results[pkgno] = didpass ? passed : failed
                        running[i] = nothing
                        put!(completed, pkgno)
                    end
                catch err
                    @error "Encountered error" exception=(err, stacktrace(catch_backtrace()))
                    stopwork!()
                    isa(err, InterruptException) || rethrow(err)
                end
            end)
        end
    end
end

const CSI = "\e["

function showresult(io::IO, dg::DependencyGraph, queue::BinaryHeap)
    npass = nfail = nskip = nrem = 0
    for res in dg.results
        if res === passed
            npass += 1
        elseif res === failed
            nfail += 1
        elseif res === skipped
            nskip += 1
        elseif res === untested
            nrem += 1
        end
    end
    print(io, "Success: ")
    printstyled(io, npass, color=:green)
    print(io, "\tFailed: ")
    printstyled(io, nfail, color=:red)
    print(io, "\tSkipped: ")
    printstyled(io, nskip, color=:yellow)
    println(io, "\tCurrent Frontier/Remaining: ", length(queue), "/", nrem)
end
