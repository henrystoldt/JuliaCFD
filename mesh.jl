# Methods from Moukalled et al. FVM - OpenFOAM, Matlab
include("vectorFunctions.jl")
include("dataStructures.jl")

######################### Mesh/Cell Geometry ###########################
function crossProd(v1::Array{Float64, 1}, v2::Array{Float64, 1})
    x = v1[2]*v2[3] - v1[3]*v2[2]
    y = -(v1[1]*v2[3] - v1[3]*v2[1])
    z = v1[1]*v2[2] - v1[2]*v2[1]
    return [x,y,z]
end

function triangleCentroid(points)
    center = [ 0.0, 0.0, 0.0 ]
    nPts = size(points, 1)
    for pt in 1:nPts
        center = center .+ points[pt]
    end
    center /= nPts

    return center
end

#Alternate name for same function
geometricCenter = triangleCentroid

function triangleArea(points::Array{Array{Float64, 1}})
    side1 = points[2] .- points[1]
    side2 = points[3] .- points[1]
    fAVec = crossProd(side1, side2) ./ 2
    return fAVec
end

#=
    Calculates face area vector and centroid from the points that make up the face
    Points must be ordered sequentially

    How it works:
        1. Splits face into subtriangles
        2. Area and centroid is computed for each subtriangle
        3. Areas vectors are summed and returned
        4. The centroid returned is obtained from an area-weighted of sum of the subtriangle centroids
=#
function faceAreaCentroid(points::Array{Array{Float64, 1}})
    gC = geometricCenter(points)
    nPts = size(points, 1)

    fAVec = [ 0.0, 0.0, 0.0 ]
    centroid = [ 0.0, 0.0, 0.0 ]

    for i in 1:nPts
        if i < nPts
            subTriPts = [ gC, points[i], points[i+1] ]
        else
            subTriPts = [ gC, points[i], points[1] ]
        end

        triCentroid = triangleCentroid(subTriPts)
        subFAVec = triangleArea(subTriPts)

        fAVec += subFAVec
        centroid += triCentroid .* mag(subFAVec)
    end

    centroid /= mag(fAVec)

    return fAVec, centroid
end

#=
    Calculates cell volume (scalar) and centroid (vector) from the points and face area vectors (fAVecs) that make up the cell
        fAVecs can be computed using the faceAreaCentroids function

    How it works:
        1. Splits cell into polygonal pyramids, each incorporating a single face and the geometric center of the cell
        2. Computes volume and centroid of each sub-pyramid
        3. Resulting volume is sum of sub-pyramid volumes, centroid is the volume-weighted sum of sub-pyramid centroids
=#
function cellVolCentroid(points, fAVecs, faceCentroids)
    gC = geometricCenter(points)
    nFaces = size(fAVecs,1)

    vol = 0.0
    centroid = [ 0.0, 0.0, 0.0 ]

    for f in 1:nFaces
        cellCenterVec = faceCentroids[f] .- gC
        subPyrVol = abs(sum(fAVecs[f] .* cellCenterVec) / 3)
        subPyrCentroid = 0.75.*faceCentroids[f] .+ 0.25.*gC

        vol += subPyrVol
        centroid += subPyrCentroid .* subPyrVol
    end

    centroid /= vol

    return vol, centroid
end

# For each face, calculates the vectors from it's owner and neighbour cell centers to it's own center
function cellCentroidToFaceVec(faceCentroids::Array{Array{Float64, 1}}, cellCentroids::Array{Array{Float64, 1}})
    #TODO: Understand ordering to make sure we're accepting faces in the order we need to pass them back in??
    nFaces = size(faceCentroids, 1)

    cellToFaceVec = zeros(nFaces, 3)

    for f in 1:nFaces
        cellToFaceVec[f,:] = faceCentroids[f] - cellCentroids
    end

    return cellToFaceVec
end

######################### Utility Functions ###########################
# Returns basic info about the mesh: nCells, nFaces, nBoundaries, nBdryFaces
function unstructuredMeshInfo(mesh::Mesh)
    nCells = size(mesh.cells, 1)
    nFaces = size(mesh.faces, 1)
    nBoundaries = size(mesh.boundaryFaces, 1)

    # Count boundary faces
    nBdryFaces = 0
    for bdry in 1:nBoundaries
        nBdryFaces += size(mesh.boundaryFaces[bdry], 1)
    end

    return nCells, nFaces, nBoundaries, nBdryFaces
end

function unstructuredMeshAdaptInfo(mesh::AdaptMesh)
    nCells = size(mesh.cells, 1)
    nFaces = size(mesh.faces, 1)
    nBoundaries = size(mesh.boundaryFaces, 1)

    # Count boundary faces
    nBdryFaces = 0
    for bdry in 1:nBoundaries
        nBdryFaces += size(mesh.boundaryFaces[bdry], 1)
    end

    return nCells, nFaces, nBoundaries, nBdryFaces
end

# Checks whether a string represents a number (using a regular expression)
function isNumber(str)
    re = r"^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$"
    return occursin(re, str)
end

######################### Parse OpenFOAM Meshes ###########################
#=
    In the points, faces, owner, and neighbour files, the beginning of useful information in the file looks like this:

        ...
        object      faces;
        }
        // * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //


        5135
        (
        4(79 1516 1380 37)
        4(1381 1422 1249 39)
        ...

    The 5135 indicates how many lines of information follow it.
    This function would return 5135, and the line number of the first piece of information in the file ((line number of 5135) + 2)
=#
function OFFile_FindNItems(fileLines)
    nLines = size(fileLines, 1)
    lineCounter = 1
    itemCount = 0
    startLine = 0
    for line in fileLines
        if isNumber(strip(line))
            itemCount = parse(Int64, line)
            startLine = lineCounter+2
            break
        end
        lineCounter += 1
    end
    return startLine, itemCount
end

#=
    Takes the file path to an OpenFOAM mesh 'points' file, returns a 2D array of point coordinates:
            X   Y   Z
        P1  x1  y1  z1
        P2  x2  y2  z2
        ...
=#
function readOFPointsFile(filePath)
    f = open(filePath)
    pointsLines = readlines(f)
    startLine, pCount = OFFile_FindNItems(pointsLines)

    points = zeros(pCount, 3)
    for line in startLine:(startLine+pCount-1)
        pLine = pointsLines[line]

        bracketsRemoved = pLine[2:end-1]
        coords = split(bracketsRemoved)
        for d in 1:3
            points[line+1-startLine, d] = parse(Float64, coords[d])
        end
    end

    return points
end

#=
    Takes the file path to an OpenFOAM mesh 'faces' file, returns a 1D array of 1D arrays.
    Each entry in the upper level array represents a single face
    Each face-array contains the indices of the points that make up that face
    Note that all indices from the file are incremented by 1, to switch from OpenFOAM's 0-based indexing to Julia's 1-based indexing

    Example return value:
        [ [face1_pt1Index, face1_pt2Index, face1_pt3Index], [face2_pt1Index, face2_pt2Index, face2_pt3Index, face2_pt4Index], ... ]
=#
function readOFFacesFile(filePath)
    f = open(filePath)
    facesLines = readlines(f)
    startLine, fCount = OFFile_FindNItems(facesLines)

    faces = []
    for line in startLine:(startLine+fCount-1)
        fLine = facesLines[line]
        facePts = []

        bracketIndex = findfirst("(", fLine)[1]
        bracketsRemoved = fLine[bracketIndex+1:end-1]
        ptNumbers = split(bracketsRemoved)
        nPts = size(ptNumbers, 1)
        for p in 1:nPts
            # Add one to convert to 1-based indexing
            push!(facePts, parse(Int64, ptNumbers[p])+1)
        end
        push!(faces, facePts)
    end

    return faces
end

#=
    Takes the file path to an OpenFOAM 'owner' file, returns a 1D array of owner cell indices
    Example return value:
        [ face1_ownerCellIndex, face2_ownerCellIndex, ...  ]
=#
function readOFOwnerFile(filePath)
    f = open(filePath)
    ownerLines = readlines(f)
    startLine, oCount = OFFile_FindNItems(ownerLines)

    faceOwnerCells = zeros(Int64, oCount)
    for line in startLine:(startLine+oCount-1)
        # Add one to convert to 1-based indexing
        faceOwnerCells[line-startLine+1] = parse(Int64, ownerLines[line])+1
    end

    return faceOwnerCells
end

#=
    Takes the file path to an OpenFOAM 'neighbour' file, returns a 1D array of neighbour cell indices
    Note that all indices from the file are incremented by 1, to switch from OpenFOAM's 0-based indexing to Julia's 1-based indexing

    Example return value:
        [ face1_neighbourCellIndex, face2_neighbourCellIndex, ...  ]
=#
function readOFNeighbourFile(filePath)
    f = open(filePath)
    neighbourLines = readlines(f)
    startLine, nCount = OFFile_FindNItems(neighbourLines)

    faceNeighbourCells = zeros(Int64, nCount)
    for line in startLine:(startLine+nCount-1)
        # Add one to convert to 1-based indexing
        faceNeighbourCells[line-startLine+1] = parse(Int64, neighbourLines[line])+1
    end

    return faceNeighbourCells
end

#=
    Returns index of first line containing str
    Otherwise returns -1
=#
function findInLines(str, lines, startLine)
    nLines = size(lines, 1)
    for i in startLine:nLines
        if occursin(str, lines[i])
            return i
        end
    end
    return -1
end

#=
    Takes the file path to an OpenFOAM 'boundary' file, returns 3 arrays:
    boundaryNames:          Array of boundary names (strings)
    boundaryNumFaces:       Array containing the number of faces in each boundary
    boundaryStartFaces:     Array containing the index of the first face in the boundary (boundaries always occupy a continuous sequence of face indices, and are usually numbered last)
=#
function readOFBoundaryFile(filePath)
    f = open(filePath)
    bLines = readlines(f)
    startLine, bCount = OFFile_FindNItems(bLines)
    nLines = size(bLines, 1)

    boundaryNames = Array{String, 1}(undef, bCount)
    boundaryStartFaces = Array{Int64, 1}(undef, bCount)
    boundaryNumFaces = Array{Int64, 1}(undef, bCount)
    for i in 1:bCount
        bNameLine = findInLines("{", bLines, startLine)-1
        boundaryNames[i] = strip(bLines[bNameLine])

        bNFacesLine = findInLines("nFaces", bLines, startLine)
        boundaryNumFaces[i] = parse(Int64, split(bLines[bNFacesLine])[2][1:end-1])

        bStartFaceLine = findInLines("startFace", bLines, startLine)
        boundaryStartFaces[i] = parse(Int64, split(bLines[bStartFaceLine])[2][1:end-1])+1

        startLine = findInLines("}", bLines, startLine)+1
    end

    return boundaryNames, boundaryNumFaces, boundaryStartFaces
end

#=
    Input: Path to an OpenFOAM mesh FOLDER.
    Output: Calls readOFPoints/Faces/Owner/NeighbourFile and returns all of their results (reads all OpenFOAM's mesh file data into arrays)
=#
function readOpenFOAMMesh(polyMeshPath)
    pointsFilePath = "$polyMeshPath/points"
    points = readOFPointsFile(pointsFilePath)
    facesFilePath = "$polyMeshPath/faces"
    faces = readOFFacesFile(facesFilePath)
    ownerFilePath = "$polyMeshPath/owner"
    owner = readOFOwnerFile(ownerFilePath)
    neighbourFilePath = "$polyMeshPath/neighbour"
    neighbour = readOFNeighbourFile(neighbourFilePath)
    boundaryFilePath = "$polyMeshPath/boundary"
    boundaryNames, boundaryNumFaces, boundaryStartFaces = readOFBoundaryFile(boundaryFilePath)

    return points, faces, owner, neighbour, boundaryNames, boundaryNumFaces, boundaryStartFaces
end

#=
    Function used to find all the points in each cell.
    Not required for CFD, which is face-based, but required for cell-based .vtk file output.

    Input: Path to an OpenFOAM mesh FOLDER.
    Returns:
        points:         Array of points obtained from readOFPoints()
        cellPtIndices:  Array of arrays, where each subarrary represents a cell, and each entry in a cell's array is the index of one of its points
=#
function OpenFOAMMesh_findCellPts(polyMeshPath)
    points, OFfaces, owner, neighbour, boundaryNames, boundaryNumFaces, boundaryStartFaces = readOpenFOAMMesh(polyMeshPath)
    nCells = maximum(owner)
    nFaces = size(OFfaces, 1)
    nBoundaries = size(boundaryNames, 1)

    cellPtIndices = Array{Array{Int64, 1}, 1}(undef, nCells)    # OUTPUT, Array of arrays, where each subarrary represents a cell, and each entry in a cell's array is the index of one of its points
    cells = Array{Array{Int64, 1}, 1}(undef, nCells)            # Indices of faces that make up a cell

    ### Populate the cells array ###
    #TODO: This code to make the cells array is nearly duplicated in OpenFOAMMesh() below. Perhaps extract it into a function.
    nOwners = size(owner, 1)
    for f in 1:nOwners
        ownerCell = owner[f]
        if isassigned(cells, ownerCell)
            push!(cells[ownerCell], f)
        else
            cells[ownerCell] = [f,]
        end
    end

    nNeighbours = size(neighbour, 1)
    for f in 1:nNeighbours
        neighbourCell = neighbour[f]
        if isassigned(cells, neighbourCell)
            push!(cells[neighbourCell], f)
        else
            cells[neighbourCell] = [f,]
        end
    end
    # fAVecs, fCenters, faces, cells now complete

    ### Using the cells array, populate the cellPtIndices array ###
    for c in 1:nCells
        pts = Array{Int64,1}(undef, 0) # Points that make up the present cell

        # Add all points from face f to pts
        function addFace(f)
            for pt in OFfaces[f]
                push!(pts, pt)
            end
        end

        # Are all points in face f currently absent from the pts array (are the arrays OFfaces[f] and pts disjont?)
        function disjoint(f)
            for pt in OFfaces[f]
                if any(x->x==pt, pts)
                    return false
                end
            end
            return true
        end

        # First face to add to the pts array. Changing the index of this face (which must be <= Number of faces in smallest cell) can change in which order points are added to the array.
            # This sometimes happens to put points in the correct order for nice-looking .vtk output
            # Current best options for each mesh: Wedge - 3
        #println("We made it to cell $c")
        addFace(cells[c][3])

        # Add any disjoint faces
        for f in cells[c]
            if disjoint(f)
                addFace(f)
            end
        end

        # Add any leftover points
        for f in cells[c]
            for pt in OFfaces[f]
                if !any(x->x==pt, pts)
                    push!(pts, pt)
                end
            end
        end

        # Store the list of points that make up the current cell
        cellPtIndices[c] = pts
    end

    return points, cellPtIndices
end

#=
    Reads an OpenFOAM mesh and returns a Mesh object suitable for calculations in JuliaCFD.

    Mesh defined in dataStructures.jl, documented in dataStructureDefintions.md
=#
function OpenFOAMMesh(polyMeshPath)
    points, OFfaces, owner, neighbour, boundaryNames, boundaryNumFaces, boundaryStartFaces = readOpenFOAMMesh(polyMeshPath)
    nCells = maximum(owner)
    nFaces = size(OFfaces, 1)
    nBoundaries = size(boundaryNames, 1)

    cells = Array{Array{Int64, 1}, 1}(undef, nCells)                # Indices of faces that make up a cell
    cVols = zeros(nCells)                                           # Cell Volumes
    cCenters = Array{Array{Float64, 1}, 1}(undef, nCells)           # Cell Centroids
    cellSizes = Matrix{Float64}(undef, nCells, 3)                   # Cell sizes (x,y,z) direction

    faces = Array{Array{Int64, 1}, 1}(undef, nFaces)                # Indices of cells adjacent to each face always owner first, then neighbour
    fAVecs = Array{Array{Float64, 1}, 1}(undef, nFaces)             # Face Area Vectors
    fCenters = Array{Array{Float64, 1}, 1}(undef, nFaces)           # Face Centroids
    boundaryFaces = Array{Array{Int64, 1}, 1}(undef, nBoundaries)   # Indices of faces that make up each boundary

    # Calculate face area vectors and face centroids from list of points in each face
    for f in 1:nFaces
        fPts = [ points[pt,:] for pt in OFfaces[f] ]
        fAVecs[f], fCenters[f] = faceAreaCentroid(fPts)
    end
    #fAVecs and fCenters now complete

    # Build 'cells' and 'faces' arrays from info from 'owner' file
    nOwners = size(owner, 1)
    for f in 1:nOwners
        ownerCell = owner[f]
        if isassigned(cells, ownerCell)
            push!(cells[ownerCell], f)
        else
            cells[ownerCell] = [f,]
        end

        faces[f] = [ownerCell, -1]
    end

    # Finish building 'cells' and 'faces' arrays, adding info from 'neighbour' file
    nNeighbours = size(neighbour, 1)
    for f in 1:nNeighbours
        neighbourCell = neighbour[f]
        if isassigned(cells, neighbourCell)
            push!(cells[neighbourCell], f)
        else
            cells[neighbourCell] = [f,]
        end

        faces[f][2] = neighbourCell
    end
    # fAVecs, fCenters, faces, cells now complete

    # For each cell, use the face area vectors and face centroids for all of its faces, to calculate it's volume and centroid location
    for c in 1:nCells
        pts = []
        for f in cells[c]
            for pt in OFfaces[f]
                if !(points[pt,:] in pts)
                    push!(pts, points[pt,:])
                end
            end
        end
        fCs = [ fCenters[f] for f in cells[c] ]
        cell_fAVecs = [ fAVecs[f] for f in cells[c] ]

        cVols[c], cCenters[c] = cellVolCentroid(pts, cell_fAVecs, fCs)
    end
    # fAVecs, fCenters, faces, cells, cVols, cCenters now complete

    # Create boundaryFaces array
    for b in 1:nBoundaries
        startF = boundaryStartFaces[b]
        endF = startF + boundaryNumFaces[b] - 1
        boundaryFaces[b] = Array(startF:endF)
    end

    # Compute cell sizes in the x, y, z directions
    # In the past, cell sizes were used for a shitty CFL calculation, may be able to get rid of them now
    maxCoords = [ -1000000.0, -1000000.0, -1000000.0 ]
    minCoords = [ 1000000.0, 1000000.0, 1000000.0 ]
    for c in 1:nCells
        fill!(maxCoords, -10000000)
        fill!(minCoords, 10000000)

        pts = Vector{Vector{Float64}}()

        # Add points
        for f in cells[c]
            for pt in OFfaces[f]
                if !any(x->x==pt, pts)
                    push!(pts, points[pt, :])
                end
            end
        end

        for pt in pts
            for d in 1:3
                maxCoords[d] = max(maxCoords[d], pt[d])
                minCoords[d] = min(minCoords[d], pt[d])
            end
        end

        for d in 1:3
            cellSizes[c,d] = maxCoords[d] - minCoords[d]
        end
    end

    return Mesh(cells, cVols, cCenters, cellSizes, faces, fAVecs, fCenters, boundaryFaces)
end


######## Mesh adaption functions ########

function createMeshAdaptStruct(mesh::Mesh, polyMeshPath)
    points, OFfaces, owner, neighbour, boundaryNames, boundaryNumFaces, boundaryStartFaces = readOpenFOAMMesh(polyMeshPath)
    nFaces = size(OFfaces, 1)
    nPoints = size(points, 1)

    fPoints = Array{Array{Int64, 1},1}(undef, nFaces)
    fPointLocs = Matrix{Float64}(undef, nPoints, 3)


    # Fills face point and face point location data structures
    for f in 1:nFaces
        fPts = []
        for pt in OFfaces[f]
            push!(fPts, pt)
            fPointLocs[pt,:] = points[pt,:]
        end
        fPoints[f] = fPts

    end

    return AdaptMesh(mesh.cells, mesh.cVols, mesh.cCenters, mesh.cellSizes, mesh.faces, mesh.fAVecs, mesh.fCenters, mesh.boundaryFaces, fPoints, fPointLocs)

end

function createFacesDataStruct(mesh::AdaptMesh, boundaryConditions)
    nCells, nFaces, nBoundaries, nBdryFaces = unstructuredMeshAdaptInfo(mesh)

    nIntFaces = nFaces-nBdryFaces

    nBoundaryTypes = []

    for i in 1:nBoundaries
        bb = 2*i-1
        push!(nBoundaryTypes, boundaryConditions[bb])
    end

    nBoundaryIndices = zeros(Int64, nBoundaries)
    nBoundaryIndices[1] = nIntFaces + 1

    for b in 1:nBoundaries-1
        nBoundaryIndices[b+1] = nBoundaryIndices[b] + size(mesh.boundaryFaces[b],1)
    end

    return FacesData(nFaces, nIntFaces, nBoundaries, nBoundaryTypes, nBoundaryIndices)
end

function adaptNewMesh(mesh::AdaptMesh, nList, boundaryConditions)
    #Pull out required lists
    facesData = createFacesDataStruct(mesh, boundaryConditions)

    newCellsList = Array{Array{Int64, 1}, 1}(undef, 0)

    cells = mesh.cells
    faces = mesh.faces
    fCenters = mesh.fCenters

    fPoints = mesh.fPoints
    fPLocs = mesh.fPointLocs

    #println("$breakdown")

    listLength = size(nList,1)

    for i in 1:listLength
        #Evaluate for PA or bisection
        adaptMethods = [pointAddition, bisection]

        usePointAddition = true

        # holder1 = size(cells,1)
        # holder2 = size(faces,1)
        # holder3 = size(fPoints,1)
        # holder4 = size(fPLocs,1)
        # holder5 = size(nList,1)
        # holder6 = cells[631:635]

        # println("Debug statement: cells $holder1, faces $holder2, fPoints $holder3, fPLocs $holder4, nList $holder5")

        if usePointAddition
            cells, faces, fCenters, fPoints, fPLocs, facesData, nList, newCellsList = adaptMethods[1](cells, faces, fCenters, fPoints, fPLocs, facesData, nList, i, newCellsList)
        else
            cells, faces, fCenters, fPoints, fPLocs, facesData, nList = adaptMethods[2](cells, faces, fCenters, fPoints, fPLocs, facesData, nList, i)
        end
    end

    # display(cells[1000:end])
    # nCells = size(cells,1)
    # nFaces = size(faces,1)
    # println("There are $nCells cells leaving adaptation, and $nFaces faces")
    # #println("$breakdown")
    #
    # holder1 = size(cells,1)
    # holder2 = size(faces,1)
    # holder3 = size(fPoints,1)
    # holder4 = size(fPLocs,1)
    # holder5 = size(nList,1)
    # #holder6 = cells[631:635]
    #
    # display(faces[3931])
    # println("Debug statement: cells $holder1, faces $holder2, fPoints $holder3, fPLocs $holder4, nList $holder5")

    #### NOTE: In its current form, this does not update cVols, cCenters, cellSizes, fAVecs, fCenters, or boundaryFaces, because this is intended to be immediately used to write a new mesh file, and they are not required
    mesh.cells = cells
    mesh.faces = faces
    mesh.fPoints = fPoints
    mesh.fPointLocs = fPLocs

    newMesh = mesh

    #println("$breakdown")
    # TODO: Error check to make sure the correct number of cells remain - seems to be right on coarse wedge mesh
    # TODO: Add a list of new cells to make the sln interpolationg possible for the future

    return newMesh, newCellsList, facesData

end

function pointAddition(cells, faces, fCen, fPoints, fPLocs, fData, nList, index, newCellsList)
    cell = nList[index]
    cellFaces = cells[cell]

    # println("Cell is: $cell ")


    #println("Faces are: $cellFaces")



    nPoints = size(fPLocs,1)
    nCells = size(cells,1)

    #Find the empty face boundary limits

    workingFaces, internalFaces = findEmptyBdryFaces(fData, cellFaces) #Implicit assumption: Mesh is 2D, so empty boundaries are mirror of each other

    if size(workingFaces,1) != 2 #Some error checking
        println("Error: wrong number of empty boundary faces found!!")
        println("$breakdown")
    end

    #Find number of points in face
    p = size(fPoints[workingFaces[1]], 1)

    workingCen = zeros(2,3)
    for i in 1:2 #Pull out face centroids
        workingCen[i,:] = fCen[workingFaces[i]]
    end

    #Pick + and - mirror faces
    (x, indexMax) = findmax(workingCen[:,3])
    (y, indexMin) = findmin(workingCen[:,3])

    posFacePts = fPoints[workingFaces[indexMax]]
    negFacePts = fPoints[workingFaces[indexMin]]

    workingPointLocs = zeros(p*2, 3)

    offset = 0

    for j in 1:p
        workingPointLocs[j,:] = fPLocs[posFacePts[j],:]
        if (workingPointLocs[j,1] == fPLocs[negFacePts[1],1]) && (workingPointLocs[j,2] == fPLocs[negFacePts[1],2])
            offset = j - 1
        end
        #workingPointLocs[j+p,:] = fPLocs[negFacePts[j],:]
    end

    newNegFacePts = zeros(Int, p)

    for j in 1:p
        new_j = p-(j+1)+offset
        new_j -= 1
        #new_j = j + offset
        if new_j < 1
            new_j = new_j + p
        end
        workingPointLocs[j+p,:] = fPLocs[negFacePts[new_j],:]
        newNegFacePts[j] = negFacePts[new_j]
    end
    negFacePts = newNegFacePts #If looping neg points to get vector out, have to loop backwards because ordering reversed

    newEmptyFaces = Array{Array{Int64, 1}}(undef, 0)

    for i in 1:p #Make new positive faces for boundary
        iPlus = i+1
        if iPlus > p
            iPlus -= p
        end
        newFace = [nPoints+1, posFacePts[i], posFacePts[iPlus]]
        #newEmptyFaces[i] = newFace
        push!(newEmptyFaces, newFace)
    end

    for i in 1:p #Now add new negative faces for boudary
        iPlus = i + 1
        if iPlus > p
            iPlus -= p
        end
        newFace = [nPoints+2, negFacePts[iPlus], negFacePts[i]]
        #newEmptyFaces[i+p][:] = newFace
        push!(newEmptyFaces, newFace)
    end

    newIntFaces = Array{Array{Int64, 1}}(undef,0)

    for i in 1:p
        newFace = [nPoints+1, posFacePts[i], negFacePts[i], nPoints+2]
        push!(newIntFaces, newFace)
    end


    #Add points to fPLocs
    newPoints = zeros(nPoints+2,3)
    newPoints[1:nPoints,:] = fPLocs
    newPoints[nPoints+1,:] = workingCen[indexMax,:] #Note: Doing it like this messes up the normal points ordering, by putting z+ points at the end instead of in the middle/first half. I don't THINK it matters though
    newPoints[nPoints+2,:] = workingCen[indexMin,:]



    # Add boundary and internal faces first to mesh

    delFaces = workingFaces
    delCell = cell

    #Add boundary faces, internal faces, and new cells. Update all required additions (Update new cell numbers in faces list as well)
    # This is also actively tracking index changes on list of lists (delCell + delFaces) - although delCell isn't changed in point addition

    #display(fPLocs[25231-6:25230])
    # fPLocs = newPoints
    # display(fPLocs[81,:])
    # display(fPLocs[3829,:])
    # #display(fPLocs[4297,:])
    # #display(fPLocs[549,:])
    # display(fPLocs[266,:])
    # display(fPLocs[4014,:])
    # println("$breakdown")
    cells, faces, fCen, fPoints, fData, delFaces, newCellsList = addFacesAndCellsToMesh(cells, faces, fCen, fPoints, fData, internalFaces, newIntFaces, newEmptyFaces, delFaces, delCell, newCellsList)

    # Now delete the required faces and cells from the mesh

    cells, faces, fCen, fPoints, fData, nList, newCellsList = removeFacesAndCellsFromMesh(cells, faces, fCen, fPoints, fData, nList, delFaces, delCell, newCellsList)

    # Now updates points

    fPLocs = newPoints

    return cells, faces, fCen, fPoints, fPLocs, fData, nList, newCellsList
end

function bisection(cells, faces, fCen, fPoints, fPLocs, fData, nList, index)

end


#=
    This function finds the empty boundary faces attached to a specific cell
=#
function findEmptyBdryFaces(fData::FacesData, cellFaces)
    emptyLower = zeros(Int, 1)
    emptyUpper = zeros(Int, 1)

    for b in 1:fData.nBdry
        if fData.bdryTypes[b] == emptyBoundary!  #This will get messed up if there's two separate sets of emptyBoundary!
            emptyLower = fData.bdryIndices[b]
            if b != fData.nBdry
                emptyUpper = fData.bdryIndices[b+1] - 1
            else
                emptyUpper = fData.nFaces
            end
        end
    end

    workingFaces = [] #Track the indices of the empty boundary faces
    internalFaces = []

    for face in cellFaces
        if (face >= emptyLower) && (face <= emptyUpper)
            push!(workingFaces, face)
        else
            push!(internalFaces, face)
        end
    end
    return workingFaces, internalFaces
end

function addFacesAndCellsToMesh(cells, faces, fCen, fPoints, fData, internalFaces, intFaces, bdryFaces, delFaces, delCell ,newCellsList)
    #delIndexes = keep track of where the cells and faces to delete go
    nCells = size(cells, 1)


    #Start with adding the boundary faces
    emptyIndexEnd = 0
    emptyBdry = 0

    for b in 1:fData.nBdry
        if fData.bdryTypes[b] == emptyBoundary!
            emptyBdry = b
            if b != fData.nBdry
                emptyIndexEnd = fData.bdryIndices[b+1]
            else
                emptyIndexEnd = fData.nFaces
            end
        end
    end

    # fPoints
    fPoints = insertArrayInt(fPoints, emptyIndexEnd, bdryFaces)

    # fCen

    newFCen = Array{Array{Float64,1} ,1}(undef,0)
    for i in 1:size(bdryFaces,1)
        push!(newFCen, [0.0, 0.0, 0.0])
    end

    fCen = insertArray(fCen, emptyIndexEnd, newFCen)

    # faces
    nBdryFacesHold = size(bdryFaces,1)
    nIntFacesHold = size(intFaces, 1)

    newBdryFaceCells = Array{Array{Int64,1} , 1}(undef, 0)
    for i in 1:size(bdryFaces,1)
        iNew = i + 1                    # Overflow bug TODO: Write a decent fix and for the one around line ~947
        if iNew > (size(intFaces,1))
            iNew -= size(intFaces,1)
        end
        if iNew > (size(intFaces,1))    #This fixes the bug if it's still too high!!
            iNew -= size(intFaces,1)
        end
        newCells = [iNew+nCells, -1]
        push!(newBdryFaceCells, newCells)
    end

    # println("New bdry face cells!")
    # display(newBdryFaceCells)

    faces = insertArrayInt(faces, emptyIndexEnd, newBdryFaceCells)

    # internalFaces

    # - shouldn't need any adjustment

    # fData

    fData.nFaces += size(bdryFaces, 1)

    for c in emptyBdry+1:fData.nBdry
        fData.bdryIndices[c] += size(bdryFaces, 1)
    end

    # cells - just updating indices for now

    for cell in 1:nCells
        for face in 1:size(cells[cell],1)
            if cells[cell][face] >= emptyIndexEnd
                cells[cell][face] += size(bdryFaces, 1)
            end
        end
    end

    # delFaces (check)

    for i in 1:size(delFaces,1)
        if delFaces[i] >= emptyIndexEnd
            delFaces[i] += size(bdryFaces, 1)
        end
    end


    ####### Interior faces now #################

    intIndexEnd = fData.bdryIndices[1]

    # fPoints

    fPoints = insertArrayInt(fPoints, intIndexEnd, intFaces)

    # fCen

    newFCen = Array{Array{Float64,1} ,1}(undef,0)
    for i in 1:size(intFaces,1)
        push!(newFCen, [0.0, 0.0, 0.0])
    end

    fCen = insertArray(fCen, intIndexEnd, newFCen)

    # faces

    newIntFaceCells = Array{Array{Int64,1} , 1}(undef, 0)
    for i in 1:size(intFaces,1)
        iPlus = i+1
        if iPlus > (size(intFaces,1))       # Don't need it because you're only looping over it the same times as the size
            iPlus -= size(intFaces,1)
        end
        newCells = [i+nCells, iPlus+nCells]
        push!(newIntFaceCells, newCells)
    end

    faces = insertArrayInt(faces, intIndexEnd, newIntFaceCells)


    # internalFaces

    # - shouldn't need any adjustment -
    # - thats where you're wrong bucko!!

    # fData

    fData.nFaces += size(intFaces, 1)
    fData.nIntFaces += size(intFaces, 1)

    for b in 1:fData.nBdry
        fData.bdryIndices[b] += size(intFaces, 1)
    end

    # cells - different treatment

    for cell in 1:nCells
        for face in 1:size(cells[cell],1)
            if cells[cell][face] >= intIndexEnd
                cells[cell][face] += size(intFaces, 1)
            end
        end
    end

    # - add new cells - with new face indices
    ## Each new cell will have five faces - four new ones, and one existing

    newCells = Array{Array{Int64, 1}, 1}(undef, 0)

    # Fix internal face indexes if any of them are boundaries

    facesAdded = size(intFaces,1) + size(bdryFaces,1)
    for i in 1:size(internalFaces, 1)
        if (internalFaces[i] > intIndexEnd) && (internalFaces[i] <= emptyIndexEnd)
            internalFaces[i] += size(intFaces,1)
        elseif internalFaces[i] > emptyIndexEnd
            internalFaces[i] += facesAdded
        end
    end


    for i in 1:size(intFaces, 1)
        iMod = i - 1
        if iMod < 1
            iMod += size(intFaces,1)
        end

        # println("Cells attached to face 3590: ")
        # display(faces[3590])
        neighbourCellFace, empty1, empty2 = findNeighbouringFace(fPoints, internalFaces, fData, emptyBdry, iMod)
        startPoint = fData.nIntFaces - size(intFaces,1)
        internalNew1 = startPoint + i
        internalNew2 = startPoint + iMod
        newCellFaces = [neighbourCellFace, internalNew1, internalNew2, empty1, empty2]

        push!(cells, newCellFaces)

        #Update neighbour cell face in faces as well

        if faces[neighbourCellFace][1] == delCell
            faces[neighbourCellFace][1] = nCells+i
        elseif faces[neighbourCellFace][2] == delCell
            faces[neighbourCellFace][2] = nCells+i
        end
    end

    # newCellsList

    newCellsListHolder = []

    for i in 1:size(intFaces,1)
        push!(newCellsListHolder, nCells+i)
    end

    push!(newCellsList, newCellsListHolder)

    # delFaces

    for i in 1:size(delFaces,1)
        if delFaces[i] >= intIndexEnd
            delFaces[i] += size(intFaces, 1)
        end
    end

    return cells, faces, fCen, fPoints, fData, delFaces, newCellsList
end

function removeFacesAndCellsFromMesh(cells, faces, fCen, fPoints, fData, nList, delFaces, delCell, newCellsList)
    # Actions to each input
    #
    #   cells   - decrement all faces by the amount of deleted cells in front of them (increments already done)
    #           - then delete the list/element corresponding to the deleted cell
    #   faces   - decrement all indices in the list above delCell by one
    #           - then delete lists/elements corresponding to deleted faces
    #   fCen    - delete rows/elements corresponding to deleted faces
    #   fPoints - delete rows/elements corresponding to deleted faces
    #   fData   - update relevent trackers while updating faces
    #   nList   - cells numbered above the deleted cell should be decremented by one (don't touch the decremented cell for now, we should be done with it after this)

    ##### Deal with faces first
    delFacesSorted = sort(delFaces, rev=true) #Sort so that we start from the highest and never have to touch this list
    for f in delFacesSorted
        for i in 1:size(cells,1)
            for j in 1:size(cells[i],1)
                if cells[i][j] > f # The cells[i][j] == f occurs only for the cell list we are going to delete, because other cases have already been updated. NOTE: not sure if true for bisection as well??
                    cells[i][j] -= 1
                end
            end
        end

        # faces, fCen, fPoints

        deleteat!(faces, f)
        deleteat!(fCen, f)
        deleteat!(fPoints, f)

        # fData
        fData.nFaces -= 1
        if f <= fData.nIntFaces
            fData.nIntFaces -= 1
        end
        for b in 1:fData.nBdry
            if f <= fData.bdryIndices[b]   # I think this is the right conditional?
                fData.bdryIndices[b] -= 1
            end
        end
    end

    ##### Now deal with cell

    for f in 1:size(faces,1)
        #If any reference is deleted cell I've done it wrong
        for cell in 1:size(faces[f],1)
            if faces[f][cell] > delCell
                faces[f][cell] -= 1

            elseif faces[f][cell] == delCell
                println("You fucked up removing faces references to dead cell!")
                println("$breakdown")
            end
        end
    end

    for i in 1:size(nList,1)
        if nList[i] > delCell
            nList[i] -= 1
        end
    end

    for i in 1:size(newCellsList,1)
        for j in 1:size(newCellsList[i],1)
            newCellsList[i][j] -= 1
        end
    end

    deleteat!(cells, delCell)

    return cells, faces, fCen, fPoints, fData, nList, newCellsList

end

function insertArrayInt(array::AbstractArray, splitIndex, newArray)
    arraySize = size(array,1)
    topArray = array[1:splitIndex-1, :]

    newArraySize = size(newArray, 1)

    hArraySize = newArraySize + size(array,1)
    holderArray = Array{Array{Int64,1}}(undef, hArraySize)

    for i in 1:splitIndex-1
        holderArray[i] = array[i]
    end

    for i in 1:newArraySize
        iPlus = i + splitIndex -1
        holderArray[iPlus] = newArray[i]
    end

    for i in splitIndex+newArraySize:arraySize+newArraySize
        iMin = i - newArraySize
        holderArray[i] = array[iMin]
    end

    return holderArray
end

function insertArray(array::AbstractArray, splitIndex, newArray)
    arraySize = size(array,1)
    topArray = array[1:splitIndex-1, :]

    newArraySize = size(newArray, 1)

    hArraySize = newArraySize + size(array,1)
    holderArray = Array{Array{Float64,1}}(undef, hArraySize)

    for i in 1:splitIndex-1
        holderArray[i] = array[i]
    end

    for i in 1:newArraySize
        iPlus = i + splitIndex -1
        holderArray[iPlus] = newArray[i]
    end

    for i in splitIndex+newArraySize:arraySize+newArraySize
        iMin = i - newArraySize
        holderArray[i] = array[iMin]
    end

    return holderArray
end

function findNeighbouringFace(fPoints, internalFaces, fData, b, i)
    p = size(internalFaces, 1)
    index = fData.bdryIndices[b+1]

    # TODO: Fix it so that triangles number consistently, because I don't know if it's lining up with the cell numbering properly
    if p == 4 # This is a filthy hack, until I find out why triangles are numbering there points differently
        faceEmpty1 = fPoints[index-(2*p)+i-1]
        faceEmpty2 = fPoints[index-p+i-1]

        faceEmptyIndex1 = index-(2*p) +i - 1
        faceEmptyIndex2 = index - p +i -1
    elseif p==3
        faceEmpty1 = fPoints[index-(2*p)+i-1]

        faceEmptyIndex1 = index-(2*p) +i - 1

        if i == 1
            faceEmpty2 = fPoints[index-1]
            faceEmptyIndex2 = index-1
        elseif i == 2
            faceEmpty2 = fPoints[index-3]
            faceEmptyIndex2 = index-3
        elseif i == 3
            faceEmpty2 = fPoints[index-2]
            faceEmptyIndex2 = index-2
        else
            println("I really didn't think this through!")
            println("$breakdown")
        end
    end


    targetPts = vcat(faceEmpty1[2:3], faceEmpty2[2:3])

    # println("Printing in findNeighbour")
    # display(p)
    # display(i)
    # display(b)
    # display(index)
    # display(faceEmpty1)
    # display(faceEmpty2)
    # display(targetPts)
    # display(fPoints[index-6:index-1])
    # println("$breakdown")

    faceIndex = -1

    for face in internalFaces
        counter = 0
        checkPts = fPoints[face]
        # println("Check pts is: $checkPts")
        for i in 1:size(checkPts,1)
            for j in 1:size(targetPts,1)
                if checkPts[i] == targetPts[j]
                    #println("Inside count, $i, $j, target is: $targetPts")
                    counter += 1
                end
            end
        end

        if counter == size(checkPts,1)
            faceIndex = face
        end
    end

    # for face in 1:size(fPoints,1)
    #     counter = 0
    #     checkPts = fPoints[face]
    #     for i in 1:size(checkPts,1)
    #         for j in 1:size(targetPts,1)
    #             if checkPts[i] == targetPts[j]
    #                 counter += 1
    #             end
    #         end
    #     end
    #
    #     if counter == size(checkPts,1)
    #         faceIndex = face
    #         println("Found a face that does work!: $face")
    #         println("$breakdown")
    #     end
    # end

    #println("Target is: $targetPts")
    # println("Internal faces are: $internalFaces")
    # display(fData.bdryIndices[2])

    if faceIndex == -1
        println("Could not find matching face!")
        println("internalFaces, fData, b, i, targetPts")
        display(internalFaces)
        #display(fData)
        display(b)
        display(i)
        display(targetPts)

        #display(fPoints[8028])


        println("$breakdown")
    end

    return faceIndex, faceEmptyIndex1, faceEmptyIndex2
end
