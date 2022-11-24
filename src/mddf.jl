# Effective number of solvent molecules, if autocorrelation, or not
solvent_nmols(R) = R.solvent.nmols - R.autocorrelation

#
# Structure to carry temporary arrays needed
#
# We need temporary buffers for reading the coordinates, a buffer to store
# a temporary array of solvent coordinates (whose length is dependent on 
# autocorrelation or not), and the indexes of the solute molecules that will
# be used as reference states for ideal gas distributions
@with_kw struct Buffer
    solute_read::Vector{SVector{3,Float64}}
    solvent_read::Vector{SVector{3,Float64}}
    ref_solutes::Vector{Int}
    list::Vector{MinimumDistance}
    indexes_in_bulk::Vector{Int}
end
function Buffer(traj::Trajectory, R::Result)
    nmol = solvent_nmols(R)
    nat = R.solvent.natomspermol*nmol
    return Buffer(
        solute_read = similar(traj.x_solute), 
        solvent_read = similar(traj.x_solvent),
        ref_solutes = zeros(Int, R.options.n_random_samples),
        list = fill(zero(MinimumDistance), nmol),
        indexes_in_bulk = fill(0, nmol)
    )
end

@testitem "Buffer" begin
    using ComplexMixtures
    using PDBTools
    using ComplexMixtures.Testing
    atoms = readPDB(Testing.pdbfile)
    options = Options(stride=5,seed=321,StableRNG=true,nthreads=1,silent=true)
    protein = Selection(select(atoms, "protein"), nmols=1)
    tmao = Selection(select(atoms, "resname TMAO"), natomspermol=14)
    traj = Trajectory("$(Testing.data_dir)/NAMD/trajectory.dcd", protein, tmao)
    R = Result(traj, options)
    b0 = ComplexMixtures.Buffer(
        solute_read = similar(traj.x_solute), 
        solvent_read = similar(traj.x_solvent),
        ref_solutes = zeros(Int, R.options.n_random_samples),
        list = fill(zero(ComplexMixtures.MinimumDistance), solvent_nmols(R)),
        indexes_in_bulk = fill(0, solvent_nmols(R))
    )
    b1 = ComplexMixtures.Buffer(traj, R)
    for field in fieldnames(ComplexMixtures.Buffer)
        @test typeof(getfield(b0, field)) == typeof(getfield(b1, field))
        @test length(getfield(b0, field)) == length(getfield(b1, field))
    end
end

#
# Defines is a molecule is a bulk molecule
#
inbulk(md::MinimumDistance,options::Options) =
    options.usecutoff ? (md.within_cutoff && md.dmin_mol > options.dbulk) : !md.within_cutoff

"""
    randomize_solvent!(system, buff, n_solvent_in_bulk, options, RNG)

$(INTERNAL)

Generate a random solvent distribution from the bulk molecules of a solvent

"""
function randomize_solvent!(system::AbstractPeriodicSystem, buff::Buffer, n_solvent_in_bulk::Int, R::Result, RNG)
    for isolvent = 1:solvent_nmols(R)
        # Choose randomly one molecule from the bulk, if there are bulk molecules
        if n_solvent_in_bulk > 0 
            jmol = buff.indexes_in_bulk[random(RNG, 1:n_solvent_in_bulk)]
        else
            jmol = random(RNG, 1:solvent_nmols(R))
        end
        # Pick coordinates of the molecule to be randomly moved
        y_new = viewmol(isolvent, system.ypositions, R.solvent) 
        # Copy the coordinates of the random solvent molecule chosen
        y_new .= viewmol(jmol, buff.solvent_read, R.solvent)
        # Randomize rotations and translation for this molecule 
        random_move!(y_new, R.irefatom, system, RNG)
    end
end

"""     
    mddf(trajectory::Trajectory, options::Options)

Function that computes the minimum-distance distribution function, atomic contributions, and 
KB integrals, given the `Trajectory` structure of the simulation and, optionally, parameters
given as a second argument of the `Options` type. This is the main function of the `ComplexMixtures` 
package. 

### Examples

```julia-repl
julia> trajectory = Trajectory("./trajectory.dcd",solute,solvent);

julia> results = mddf(trajectory);
```

or, to set some custom optional parameter,

```julia-repl
julia> options = Options(lastframe=1000);

julia> results = mddf(trajectory,options);
```

"""
function mddf(trajectory::Trajectory, options::Options=Options())

    # Set random number generator
    RNG = init_random(options)

    # Number of threads (chunks) to use
    nchunks = options.nthreads
    if nchunks == 0
        nchunks = Threads.nthreads()
    end

    # Structure in which the final results will be stored
    R = Result(trajectory, options)

    # Initializing the structure that carries the result per thread
    R_chunk = [Result(trajectory, options) for _ in 1:nchunks]

    # Create data structures required for multithreading: needed to read coordinates in each
    # frame independently, and compute the minimum-distance list 
    system = [setup_PeriodicSystem(trajectory, options) for _ in 1:nchunks]
    buff = [Buffer(trajectory, R) for _ in 1:nchunks]

    # Open the trajectory stream and go to first frame
    opentraj!(trajectory)
    firstframe!(trajectory)

    # Skip initial frames if desired
    iframe = 0 # Counter for all frames of the input file, that must be read serially
    while iframe < options.firstframe - 1
        nextframe!(trajectory)
        iframe += 1
    end

    # Print some information about this run
    if !options.silent 
        title(R, trajectory.solute, trajectory.solvent, nchunks)
        progress = Progress(R.nframes_read, 1)
    end

    # Loop over the trajectory
    read_lock = ReentrantLock()
    Threads.@threads for (frame_range, ichunk) in ChunkSplitters.chunks(1:R.nframes_read, nchunks)
        # Reset the number of frames read by each chunk
        R_chunk[ichunk].nframes_read = 0
        for _ in frame_range
            # Read frame coordinates
            lock(read_lock) do 
                # skip frames if stride > 1
                while (iframe+1)%options.stride != 0
                    nextframe!(trajectory)
                    iframe += 1
                end
                # Read frame for computing 
                iframe += 1
                nextframe!(trajectory)
                # The solute coordinates must be read in intermediate arrays, because the 
                # solute molecules will be considered one at a time in the computation of the
                # minimum distances
                @. buff[ichunk].solute_read = trajectory.x_solute
                @. buff[ichunk].solvent_read = trajectory.x_solvent
                update_unitcell!(system[ichunk], getsides(trajectory, iframe))
                # Run GC if memory is getting full: this are issues with Chemfiles reading scheme
                if options.GC && (Sys.free_memory() / Sys.total_memory() < options.GC_threshold)
                    GC.gc() 
                end
                options.silent || next!(progress)
            end # release reading lock
            R_chunk[ichunk].nframes_read += 1
            # Compute distances in this frame and update results
            mddf_frame!(R_chunk[ichunk], system[ichunk], buff[ichunk], options, RNG)
        end # frame range for this chunk
    end
    closetraj!(trajectory)

    # Sum up the counts of all threads into the data of thread one (R1<-R1+R2)
    for ichunk in eachindex(R_chunk)
        sum!(R, R_chunk[ichunk])
    end

    # Setup the final data structure with final values averaged over the number of frames,
    # sampling, etc, and computes final distributions and integrals
    finalresults!(R, options, trajectory)
    options.silent || println(bars)

    return R
end

# Compute cell volume from unitcell matrix
cell_volume(system::AbstractPeriodicSystem) = @views dot(cross(system.unitcell[:,1],system.unitcell[:,2]),system.unitcell[:,3])

"""
    mddf_frame!(R::Result, system::AbstractPeriodicSystem, buff::Buffer, options::Options, RNG)

$(INTERNAL)

Computes the MDDF for a single frame, for autocorrelation of molecules. Modifies the data in the `R` (type `Result`) structure.

"""
function mddf_frame!(R::Result, system::AbstractPeriodicSystem, buff::Buffer, options::Options, RNG)

    # Sum up the volume of this frame
    R.volume.total += cell_volume(system)

    # Random set of solute molecules to use as reference for the ideal gas distributions
    for i in eachindex(buff.ref_solutes)
        buff.ref_solutes[i] = random(RNG, 1:R.solute.nmols)
    end

    #
    # Compute the MDDFs for each solute molecule
    #
    for isolute = 1:R.solute.nmols

        # We need to do this one solute molecule at a time to avoid exploding the memory requirements
        system.xpositions .= viewmol(isolute, buff.solute_read, R.solute)

        # Copy (restore) the data from buff.solvent_read, appropriately (skipping the current molecule if autocorrelation)
        if R.autocorrelation
            iymol = 0
            for imol = 1:R.solvent.nmols
                imol == isolute && continue
                iymol += 1
                ymol = viewmol(iymol, system.ypositions, R.solvent)
                ymol .= viewmol(imol, buff.solvent_read, R.solvent)
            end
        else
            system.ypositions .= buff.solvent_read
        end

        # Compute minimum distances of the molecules to the solute (updates system.list, and returns it)
        minimum_distances!(system, R)
        @show system.list

        # For each solute molecule, update the counters (this is highly suboptimal, because
        # within updatecounters there are loops over solvent molecules, in such a way that
        # this will loop with cost nsolute*nsolvent. However, I cannot see an easy solution 
        # at this point with acceptable memory requirements
        updatecounters!(R, system)

        # If this molecule was chosen as a reference molecule for the ideal gas distribution, compute it
        # (as many times as needed, as the reference molecules may be repeated - particularly because
        # there may be only one solute molecule, in which case all distributions will be created for
        # the same solute molecule).

        # Save coordinates and list for using data in ideal gas generator
        buff.list .= system.list

        # Annotate the indexes of the molecules that are in the bulk solution
        n_solvent_in_bulk = 0
        for i in eachindex(system.list)
            if inbulk(system.list[i],options)
                n_solvent_in_bulk += 1
                buff.indexes_in_bulk[n_solvent_in_bulk] = i
            end
        end

        # Generate random solvent distribution, as many times as needed to satisfy options.n_random_samples
        for _ in 1:count(==(isolute), buff.ref_solutes)
            # Randomize solvent molecules
            randomize_solvent!(system, buff, n_solvent_in_bulk, R, RNG)

            # Compute minimum distances in this random configurations
            minimum_distances!(system, R)

            # Update the counters of the random distribution
            updatecounters!(R, system, Val(:random))
        end

    end # loop over solute molecules

    return R
end

@testitem "mddf" begin
    using ComplexMixtures
    using PDBTools
    using ComplexMixtures.Testing

    # Test simple two-molecule system
    options = Options(seed=321,StableRNG=true,nthreads=1,silent=true,n_random_samples=10^5)
    atoms = readPDB("$(Testing.data_dir)/simple.pdb")
    protein = Selection(select(atoms, "protein"), nmols=1)
    water = Selection(select(atoms, "resname WAT"), natomspermol=3)
    traj = Trajectory("$(Testing.data_dir)/simple.pdb", protein, water, format="PDBTraj")

    R = mddf(traj, options)

    @test R.volume.total == 27000.0
    @test R.volume.domain ≈ (4π/3) * R.dbulk^3
    @test R.density.solute ≈ 1 / R.volume.total
    @test R.density.solvent ≈ 3 / R.volume.total
    @test R.density.solvent_bulk = 2 / R.volume.bulk

    # Test actual system
    options = Options(stride=5,seed=321,StableRNG=true,nthreads=1,silent=true)
    atoms = readPDB(Testing.pdbfile)
    protein = Selection(select(atoms, "protein"), nmols=1)
    tmao = Selection(select(atoms, "resname TMAO"), natomspermol=14)
    traj = Trajectory("$(Testing.data_dir)/NAMD/trajectory.dcd", protein, tmao)
    R = mddf(traj, options)

end