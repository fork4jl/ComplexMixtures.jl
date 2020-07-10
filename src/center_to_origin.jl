# Translates atoms of vectory in x array such that center is in the origin
function center_to_origin!(x,center)
  for i in 1:size(x,1)
    for j in 1:3
      x[i,j] = x[i,j] - center[j]
    end
  end
end
