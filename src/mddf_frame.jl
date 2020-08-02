#
# Computes the MDDF for a single frame, modifies the data in the R (Result) structure
#

function mddf_frame!(iframe :: Int64, framedata :: FrameData, options :: Options, R :: Result)

  # Simplify code by assigning some shortened names
  trajectory = framedata.trajectory
  volume_frame = framedata.volume_frame
  rdf_count_random_frame = framedata.rdf_count_random_frame
  box = framedata.box
  solute_center = framedata.solute_center
  dc = framedata.dc
  dmin_mol = framedata.dmin_mol
  dref_mol = framedata.dref_mol
  x_solvent_random = framedata.x_solvent_random
  lc_solvent = framedata.lc_solvent
  nsamples = framedata.nsamples
  moveaux = framedata.moveaux
  solute = trajectory.solute
  solvent = trajectory.solvent
  x_solute = trajectory.x_solute
  x_solvent = trajectory.x_solvent

  # Reset counters for this frame
  reset!(volume_frame)
  @. rdf_count_random_frame = 0.
  
  # get pbc sides in this frame
  sides = getsides(trajectory,iframe)

  volume_frame.total = sides[1]*sides[2]*sides[3]
  R.volume.total = R.volume.total + volume_frame.total
  
  R.density.solute = R.density.solute + (solute.nmols / volume_frame.total)
  R.density.solvent = R.density.solvent + (solvent.nmols / volume_frame.total)

  # Add the box side information to the box structure, in this frame
  @. box.sides = sides
  # Compute the number of cells in each dimension
  @. box.nc = max(1,trunc(Int64,box.sides/(options.cutoff/box.lcell)))
  @. box.l = box.sides/box.nc

  # Will wrap everthing relative to the reference atom of the first molecule
  # and move everything such that that center is in the origin. This is important
  # to simplify the computation of cell indexes, as the minimum coordinates are 
  # automatically -side/2 at each direction
  @. solute_center = x_solute[R.irefatom,1:3]
  wrap!(x_solute,sides,solute_center)
  center_to_origin!(x_solute,solute_center)
  wrap!(x_solvent,sides,solute_center)
  center_to_origin!(x_solvent,solute_center)

  # Initialize linked cells
  initcells!(x_solvent,box,lc_solvent)

  # Check if the cutoff is not too large considering the periodic cell size
  if options.cutoff > sides[1]/2. || options.cutoff > sides[2]/2. || options.cutoff > sides[3]/2.
    error("in MDDF: cutoff or dbulk > periodic_dimension/2 in frame: $iframe")
  end

  n_solvent_in_bulk = 0
  local n_solvent_in_bulk_last
  for isolute in 1:solute.nmols
    # We need to do this one solute molecule at a time to avoid exploding the memory
    # requirements
    x_this_solute = viewmol(isolute,x_solute,solute)

    # Compute all distances between solute and solvent atoms which are smaller than the 
    # cutoff (this is the most computationally expensive part), the distances are returned
    # in the dc structure
    cutoffdistances!(options.cutoff,x_this_solute,x_solvent,lc_solvent,box,dc)

    # For each solute molecule, update the counters (this is highly suboptimal, because
    # within updatecounters there are loops over solvent molecules, in such a way that
    # this will loop with cost nsolute*nsolvent. However, I cannot see an easy solution 
    # at this point with acceptable memory requirements
    n_solvent_in_bulk_last = updatecounters!(R,solute,solvent,dc,options,dmin_mol,dref_mol)
    n_solvent_in_bulk += n_solvent_in_bulk_last
  end

  #
  # Computing the random-solvent distribution to compute the random minimum-distance count
  #
  for i in 1:options.n_random_samples

    # generate random solvent box, and store it in x_solvent_random
    for j in 1:solvent.nmols
      # Choose randomly one molecule from the bulk, if there are actually bulk molecules
      if n_solvent_in_bulk_last != 0
        jmol = dmin_mol[rand(solvent.nmols-n_solvent_in_bulk_last+1:solvent.nmols)].jmol
      else
        jmol = rand(1:solvent.nmols)
      end
      # Indexes of this molecule in the x_solvent array
      x_ref = viewmol(jmol,x_solvent,solvent)
      # Indexes of the random molecule in random array
      x_rnd = viewmol(j,x_solvent_random,solvent)
      # Generate new random coordinates (translation and rotation) for this molecule
      random_move!(x_ref,R.irefatom,sides,x_rnd,moveaux)
    end

    # wrap random solvent coordinates to box, with the center at the origin
    wrap!(x_solvent_random,sides)

    # Initialize linked cells
    initcells!(x_solvent_random,box,lc_solvent)

    # Choose randomly one solute molecule to be the solute in this sample
    i_rand_mol = rand(1:solute.nmols)
    x_this_solute = viewmol(i_rand_mol,x_solute,solute)

    # Compute all distances between solute and solvent atoms which are smaller than the 
    # cutoff (this is the most computationally expensive part), the distances are returned
    # in the dc structure
    cutoffdistances!(options.cutoff,x_this_solute,x_solvent_random,lc_solvent,box,dc)

    # Update the counters of the random distribution
    updatecounters!(R.irefatom,R.md_count_random,rdf_count_random_frame,
                    solvent,dc,options,dmin_mol,dref_mol)


  end # random solvent sampling

  # Update counters with the data of this frame
  update_counters_frame!(R, rdf_count_random_frame, volume_frame, solute,
                         nsamples, n_solvent_in_bulk)

end