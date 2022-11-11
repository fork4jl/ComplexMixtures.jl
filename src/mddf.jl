#
# Structure to carry temporary arrays needed
#
# We need temporary buffers for reading the coordinates, a buffer to store
# a temporary array of solvent coordinates (whose length is dependent on 
# autocorrelation or not), and the indexes of the solute molecules that will
# be used as reference states for ideal gas distributions
@with_kw struct Buffer
    solute_read::Vector{Float64}
    solvent_read::Vector{Float64}
    solvent_tmp::Vector{Float64}
    ref_solutes::Vector{Int}
end
function Buffer(t::Trajectory, R::Result)
    return Buffer(
        solute_read = similar(t.x_solute), 
        solvent_read = similar(t.x_solvent),
        solvent_tmp = similar(t.x_solvent, length(t.x_solvent) - R.autocorrelation*t.solvent.natomspermol),
        ref_solutes = zeros(Int, R.options.n_random_samples),
    )
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

    # Initialize periodic system for CellListMap
    system = setup_PeriodicSystem(R.autocorrelation, trajectory, options)    

    # Create data structures required for multithreading: needed to read coordinates in each
    # frame independently, and compute the minimum-distance list 
    systems_chunk = [setup_PeriodicSystem(comp_type, trajectory, options) for _ in 1:nchunks]
    buff = [Buffer(trajectory, R) for _ in 1:nchunks]

    # Skip initial frames if desired
    iframe = 0 # Counter for all frames of the input file, that must be read serially
    while iframe < options.firstframe - 1
        nextframe!(trajectory)
        iframe += 1
    end

    # Print some information about this run
    options.silent || title(R, trajectory.solute, trajectory.solvent, nchunks)

    if !options.silent
        progress = Progress(R.nframes_read, 1)
    end
    read_lock = ReentrantLock()
    Threads.@threads for (frame_range, ichunk) in chunks(1:R.nframes_read, nchunks)
        # Reset the number of frames read by each chunk
        R_chunk[ichunk].nframes_read = 0
        for _ in frame_range
            # Read frame coordinates
            lock(read_lock) do 
                iframe += 1
                while (iframe+1)%options.stride != 0
                    nextframe!(trajectory)
                    iframe += 1
                end
                # The solute coordinates must be read in intermediate arrays, because the 
                # solute molecules will be considered one at a time in the computation of the
                # minimum distances
                @. buff[ichunk].solute_read = trajectory.x_solute
                @. buff[ichunk].solvent_read = trajectory.x_solvent
                update_unitcell!(system_chunk[ichunk], getsides(trajectory, iframe))
                # Run GC if memory is getting full: this are issues with Chemfiles reading scheme
                if options.GC && (Sys.free_memory() / Sys.total_memory() < options.GC_threshold)
                    GC.gc() 
                end
                next!(progress)
            end # release reading lock
            R_chunk[ichunk].nframes_read += 1
            # Compute distances in this frame and update results
            mddf_frame!(R_chunk[ichunk], system_chunk[ichunk], buff[ichunk], options, RNG)
        end # frame range for this chunk
    end
    closetraj(trajectory)

    # Sum up the results of all threads into the data of thread one (R1<-R1+R2)
    for ichunk in 1:nchunks
        R = sum!(R, R_chunk[ichunk])
    end

    # Setup the final data structure with final values averaged over the number of frames,
    # sampling, etc, and computes final distributions and integrals
    finalresults!(R, options, trajectory)
    options.silent || println(bars)

    return R
end

import .CellListMap.PeriodicSystems: AbstractPeriodicSystem

# Compute cell volume from unitcell matrix
function cell_volume(system::AbstractPeriodicSystem)  
    if unitcelltype(system) == CellListMap.OrthorhombicCell
        prod(box.unit_cell.matrix[i,i] for i in 1:3)
    else
        error("Only Orthorhombic cells are currently supported.")
    end
end

"""
    mddf_frame!(R, system_chunk, coor_read, options, RNG)

$(INTERNAL)

Computes the MDDF for a single frame, for autocorrelation of molecules. Modifies the data in the `R` (type `Result`) structure.

"""
function mddf_frame!(R::Result, system::AbstractPeriodicSystem, buff::Buffer, options::Options, RNG)

    # Initialize coordinates of the solvent: for autocorrelations, skip the first molecule
    if R.autocorrelation
        n_solvent_molecules = R.solvent.nmols - 1
        system.ypositions .= buff.solvent_read[R.solvent.n_atoms_per_molecule+1:end]
    else
        n_solvent_molecules = R.solvent.nmols
        system.ypositions .= buff.solvent_read
    end

    volume_frame.total = cell_volume(system)
    R.volume.total = R.volume.total + volume_frame.total

    R.density.solute = R.density.solute + (solute.nmols / volume_frame.total)
    R.density.solvent = R.density.solvent + (solvent.nmols / volume_frame.total)

    # Random set of solute molecules to use as reference for the ideal gas distributions
    for _ in 1:options.n_random_samples
        buff.ref_solutes = rand(1:solute.nmols)
    end

    # Counters for the number of atom in the bulk solution
    av_solvent_atoms_in_bulk = 0.0
    av_solvent_atoms_in_bulk_random = 0.0

    # Compute the MDDFs for each solute molecule
    for isolute = 1:solute.nmols
        # We need to do this one solute molecule at a time to avoid exploding the memory requirements
        system.xpositions .= viewmol(isolute, buff.solute_read, trajectory.solute)

        # Compute minimum distances of the molecules to the solute (updates system.list, and returns it)
        minimum_distances!(system, options)
    
        # Add the number of solvent atoms in bulk 
        if !options.usecutoff
            av_solvent_atoms_in_bulk += count(md -> !md.within_cutoff, system.list)
        else
            av_solvent_atoms_in_bulk += count(md -> (md.within_cutoff && md.dmin_mol > options.dbulk), system.list)
        end

        # For each solute molecule, update the counters (this is highly suboptimal, because
        # within updatecounters there are loops over solvent molecules, in such a way that
        # this will loop with cost nsolute*nsolvent. However, I cannot see an easy solution 
        # at this point with acceptable memory requirements
        updatecounters!(R, system)

        # If this molecule was chosen as a reference molecule for the ideal gas distribution, compute it
        # (as many times as needed, as the reference molecules may be repeated - particularly because
        # there may be only one solute molecule, in which case all distributions will be created for
        # the same solute molecule).
        for i in 1:count(==(isolute), buff.ref_solutes)
            # Copy solvent coordinates to temporary buffer
            buff.solvent_tmp .= system.ypositions

            # generate random solvent box, and store it in x_solvent_random
            for j = 1:n_solvent_molecules
                # Choose randomly one molecule from the bulk, if there are bulk molecules
                if n_solvent_in_bulk > 0 
                    irnd = rand(1:n_solvent_in_bulk)
                    icount = 0
                    jmol = 0
                    while icount < irnd 
                        jmol += 1
                        icount += !system.list[jmol].within_cutoff
                    end
                else
                    jmol = rand(1:n_solvent_molecules)
                end
                # Pick coordinates of the molecule to be randomly moved
                y_new = viewmol(jmol, trajectory.ypositions, solvent) 
                y_new .= buff.solvent_tmp[mol_range(jmol, R.solvent.n_atoms_per_molecule)]
                # Randomize rotations and translation for this molecule 
                random_move!(y_new, R.irefatom, sides, RNG)
            end

            # Compute minimum distances in this random configurations
            minimum_distances!(system, options)

            # Count the number of random molecules in the bulk solution
            if !options.usecutoff
                av_solvent_atoms_in_bulk_random += count(md -> !md.within_cutoff, system.list)
            else
                av_solvent_atoms_in_bulk_random += count(md -> (md.within_cutoff && md.dmin_mol > options.dbulk), system.list)
            end

            # Update the counters of the random distribution
            updatecounters!(R, system; random = true)

            # restore system coordinates 
            system.ypositions .= buff.solvent_tmp

        end # ideal gas distribution

        # Swap the coordinates of the reference molecule to the next one
        if R.autocorrelation && isolute < solute.nmols
            ir = mol_range(isolute, R.solute.n_atoms_per_molecule)
            jr = mol_range(isolute+1, R.solute.n_atoms_per_molecule)
            system.ypositions[mol_range(ir)] .= coors.y[mol_range(jr)]
        end

    end # loop over solute molecules

    # Normalize counters of solvent atoms in bulk by the number of samples
    av_solvent_atoms_in_bulk /= solute.nmols
    av_solvent_atoms_in_bulk_random /= options.n_random_samples

    # Sum up to the density of the solvent in bulk (will be normalized by the summed volume later)
    R.densities.solvent.bulk += av_solvent_atoms_in_bulk

    if R.autocorrelation
        # The normalization below is tricky. The number that comes out from updatecounters is the
        # sum, for every solvent molecule (minus one) of the distances that were not found to be in
        # the solute domain. The total number of distances is n^2, because the sum inside updatecounter
        # is made for all molecules (the same function is used for cross-distribution), but we called updatecounters
        # only (n-1) times, so the actual sum of the distances considered is n(n-1). From this set
        # the number of distances returned in n_dref_in_bulk is r=n(n-1)-nd/2, where nd is the
        # number of distances in the domain. Thus, the number of distances in the domain, considering
        # symmetric terms, is nd=2n(n-1)-2r. The average number of distances in the domain, per
        # molecule, is thus nd/n=2(n-1)-2r/n. Finally, the number of solvent molecules in 
        # bulk, for each molecule, is the total number of other molecules, (n-1), minus the
        # number of molecules in the domain, that is (n-1)-nd/n=(n-1)-2(n-1)+2r/n, which
        # finally simplifies to 2r/n-(n-1), which is the equation below. 
        n_solvent_in_bulk = 2 * n_solvent_in_bulk / solvent.nmols - (solvent.nmols - 1)
    else
        n_solvent_in_bulk = n_solvent_in_bulk / solute.nmols
    end

    return R
end








