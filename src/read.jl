#
# Function to read the json saved results file into the Result data structure
#

function read(filename :: String)
  f = open(filename,"r")
  r = JSON3.read(f,Result)
  # Need to reshape the solute and solvent atom contributions, because
  # the data is read in a single column
  return Result(r.nbins,
                r.dmax,
                r.d,
                r.md_count,
                r.md_count_random,
                r.sum_md_count,
                r.sum_md_count_random,
                r.mddf,
                r.kb,
                reshape(r.solute_atom,r.nbins,:),
                reshape(r.solvent_atom,r.nbins,:),
                r.rdf_count,
                r.rdf_count_random,
                r.sum_rdf_count,
                r.sum_rdf_count_random,
                r.rdf,
                r.kb_rdf,
                r.density,
                r.volume,
                r.options,
                r.irefatom,
                r.lastframe_read,
                r.nframes_read)
end
