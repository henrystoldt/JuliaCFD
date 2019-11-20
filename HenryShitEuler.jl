using Plots
using Plots.PlotMeasures
using LaTeXStrings
plotly()

################### Mesh Format Definition ####################
# Cells and faces are numbered according to their storage location in the mesh arrays
# Face area vector point outward from the owner cells, into the neighbour cell
# Mesh is defined as a face-based tuple containing:
# (
#     cells (list of lists, each containing the index of the faces that make up the cell)
#     faces (list of lists, each sublist containing two cell indices: the owner cell and the neighbour cell
#     fAVectors (list of face area vectors)
#     cellVolumes (list of cell volumes)
# )

######################### Utility Functions ########################
# Assumes sizes are equal - use it properly!
function dot(vec1, vec2)
    sum = 0
    for i in 1:size(vec1, 1)
        sum += vec1[i]*vec2[i]
    end
    return sum
end

######################### Constitutive Relations #######################
function idealGasRho(T, P, R=287.05)
    return P/(R*T)
end

function idealGasP(rho, T, R=287.05)
    # PV = mRT
    # P = rho R T
    return rho*R*T
end

function calPerfectEnergy(T, Cp=1005, R=287.05)
    return T*(Cp-R)
end

function calPerfectT(e, Cp=1005, R=287.05)
    return e/(Cp-R)
end

function decodePrimitives(rho, xMom, eV2, R=287.05, Cp=1005)
    U = xMom / rho
    e = (eV2/rho) - U*U/2
    T = calPerfectT(e, Cp)
    P = idealGasP(rho, T, R)
    return P, T, U
end

function encodePrimitives(P, T, U, R=287.05, Cp=1005)
    rho = idealGasRho(T, P)
    xMom = U*rho
    e = calPerfectEnergy(T)
    eV2 = rho*(e + U*U/2)
    return rho, xMom, eV2
end

######################### Gradient Computation #######################
function forwardGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[n] = 0
        for i in 1:n-1
            grad[i] = (vals[i+1] - vals[i]) / dx[i]
        end
        push!(result, grad)
    end
    return result
end

function backwardGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        for i in 2:n
            grad[i] = (vals[i] - vals[i-1])/dx[i-1]
        end
        push!(result, grad)
    end
    return result
end

function centralGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = (vals[i+1] - vals[i-1])/(dx[i] + dx[i-1])
        end
        push!(result, grad)
    end
    return result
end

function upwindGradient(dx, U, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)

        if U[1] > 0
            grad[1] = 0
        end
        if U[n] <= 0
            grad[n] = 0
        end
        
        for i in 1:n
            if U[i] > 0 && i > 1
                grad[i] = (vals[i] - vals[i-1])/dx[i-1]
            elseif U[i] == 0 && i > 1 && i < n
                grad[i] = (vals[i+1] - vals[i-1]) / (dx[i-1] + dx[i])
            elseif i < n
                grad[i] = (vals[i+1] - vals[i])/dx[i]
            end
        end
        push!(result, grad)
    end
    return result
end

# Just the numerator of the central second gradient, used for artificial diffusion term
function central2GradNum(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = vals[i+1] - 2*vals[i] + vals[i-1]
        end
        push!(result, grad)
    end
    return result
end

# Denominator of artificial diffusion term
function central2GradDenom(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = vals[i+1] + 2*vals[i] + vals[i-1]
        end
        push!(result, grad)
    end
    return result
end

####################### Face value interpolation ####################
# Interpolates to all interior faces
function upwindInterp(mesh, U, values...)
    result = []
    for vals in values
        n = size(vals,1) + 1
        fVals = Array{Float64, 1}(undef, n)

        # Faces on boundaries not treated, these must be set externally
        fVals[1] = 0
        fVals[n] = 0

        
        processedFaces = Set((1, n))
        for i in 2:n-1

            if 
            fVals[i] = 

            push!(processedFaces, i)
        end
        push!(result, grad)
    end
    return result
end

######################### Boundary Conditions #######################
function copyValues(fromIndex, toIndex, varArrays)
    for varArray in varArrays
        varArray[toIndex] = varArray[fromIndex]
    end
end

######################### Initialization #######################
function initializeShockTubeFDM(nCells=100, domainLength=1)
    # Create arrays to store data (cell # = position in array)
    dx = Array{Float64, 1}(undef, nCells)
    U = Array{Float64, 1}(undef, nCells)
    P = Array{Float64, 1}(undef, nCells)
    T = Array{Float64, 1}(undef, nCells)

    # Apply initial conditions (Fig. 1 in Henry's paper)
    for i in 1:nCells
        if i <= (nCells/2)
            T[i] = 0.00348432
            P[i] = 1
        else
            T[i] = 0.00278746
            P[i] = 0.1
        end
        U[i] = 0

        # dx = Distance between cell centers i and i+1
        dx[i] = domainLength / nCells
    end

    return dx, P, T, U
end

function initializeShockTubeFVM(nCells=100, domainLength=1)
    dx, P, T, U = initializeShockTubeFDM(nCells, domainLength)

    #Shock tube dimensions
    h = 0.1
    w = 0.1
    fAVec = (h*w, 0, 0)
    cV = h*w*domainLength/nCells

    # Indices of faces that form each cell
    cells = []
    # Indices of owner and neighbour cells for each face
    faces = []
    # face areas vectors
    fAVecs = []
    # cell volumes
    cVols = []

    push!(faces, (0, 1))
    for i in 1:nCells
        U[i] = [0, 0, 0]
        push!(cells, (i, i+1))
        push!(faces, (i, i+1))
        push!(cVols, cV)
        push!(fAVecs, fAVec)
    end

    # Last boundary face
    push!(fAVecs, fAVec)

    # Returns in mesh format
    return [ cells, faces, fAVecs, cVols ]
end

############################ Plotting ############################
function plotShockTubeResults(P, U, T, rho)
    plots = []
    xAxis = Array{Float64, 1}(undef, nCells)
    for i in 1:nCells
        xAxis[i] = i/nCells - 1/(2*nCells)
    end

    pPlot = plot(xAxis, P, label="P (Pa)", title="Pressure", xlabel="x (m)", bottom_margin=15mm, left_margin=10mm)
    rhoPlot = plot(xAxis, rho, label="rho (kg/m3)", title="Density", xlabel="x (m)", bottom_margin=15mm, left_margin=10mm)
    uPlot = plot(xAxis, U, label="Velocity (m/s)", title="Velocity", xlabel="x (m)", bottom_margin=15mm, left_margin=10mm)
    TPlot = plot(xAxis, T, label="T (K)", title="Temperature", xlabel="x (m)", bottom_margin=15mm, left_margin=10mm)
    plots = [pPlot, rhoPlot, uPlot, TPlot]
    plot(plots..., layout=(2, 2), size=(1720, 880), window_title="Euler1D_Draft_Henry", legend=false)
    gui()
end

######################### Solvers #######################
# Pass in initial values for each variable
# Shock Tube (undisturbed zero gradient) boundary conditions assumed
#TODO: Issue with shock position, check equations
function macCormack1DFDM(dx, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.5, gamma=1.4, R=287.05, Cp=1005, Cx=0.3)
    nCells = size(dx, 1)

    rho = Array{Float64, 1}(undef, nCells)
    e = Array{Float64, 1}(undef, nCells)

    for i in 1:nCells
        rho[i] = idealGasRho(T[i], P[i])
        e[i] = calPerfectEnergy(T[i])
    end

    drhoPred = Array{Float64, 1}(undef, nCells)
    duPred = Array{Float64, 1}(undef, nCells)
    dePred = Array{Float64, 1}(undef, nCells)

    rhoPred = Array{Float64, 1}(undef, nCells)
    TPred = Array{Float64, 1}(undef, nCells)
    UPred = Array{Float64, 1}(undef, nCells)
    PPred = Array{Float64, 1}(undef, nCells)
    ePred = Array{Float64, 1}(undef, nCells)

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end

        ############## Predictor #############
        drhodx, dudx, dpdx, dedx = backwardGradient(dx, rho, U, P, e)
        pCentralGrad, rhoCG, uCG, eCG = central2GradNum(dx, P, rho, U, e)
        pDenom = central2GradDenom(dx, P)[1]

        for i in 2:(nCells-1)
            # Eq. 6.1, 6.2, 6.4
            drhoPred[i] = -(rho[i]*dudx[i] + U[i]*drhodx[i])
            duPred[i] = -(U[i]*dudx[i] + dpdx[i]/rho[i])
            dePred[i] = -(U[i]*dedx[i] + P[i]*dudx[i]/rho[i])

            S = Cx * abs(pCentralGrad[i])/pDenom[i]
            rhoPred[i] = rho[i] + drhoPred[i]*dt + S*rhoCG[i]
            UPred[i] = U[i] + duPred[i]*dt + S*uCG[i]
            ePred[i] = e[i] + dePred[i]*dt + S*eCG[i]
            TPred[i] = calPerfectT(ePred[i])
            PPred[i] = idealGasP(rhoPred[i], TPred[i])
        end

        ############### Corrector ################
        drhodx, dudx, dpdx, dedx = forwardGradient(dx, rhoPred, UPred, PPred, ePred)
        pCentralGrad, rhoCG, uCG, eCG = central2GradNum(dx, PPred, rhoPred, UPred, ePred)
        pDenom = central2GradDenom(dx, PPred)[1]

        for i in 2:(nCells-1)
            drhoPred2 = -(rhoPred[i]*dudx[i] + UPred[i]*drhodx[i])
            duPred2 = -(UPred[i]*dudx[i] + dpdx[i]/rhoPred[i])
            dePred2 = -(UPred[i]*dedx[i] + PPred[i]*dudx[i]/rhoPred[i])

            # Perform timestep using average gradients
            S = Cx * abs(pCentralGrad[i])/pDenom[i]
            rho[i] += (drhoPred2 + drhoPred[i])*dt/2 + S*rhoCG[i]
            U[i] += (duPred2 + duPred[i])*dt/2 + S*uCG[i]
            e[i] += (dePred2 + dePred[i])*dt/2 + S*eCG[i]
            T[i] = calPerfectT(e[i])
            P[i] = idealGasP(rho[i], T[i])
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatemnt doesn't need to be good
        allVars = [ rho, U, e, T, P ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells, nCells, allVars)
        
        ############## CFL Calculation, timestep adjustment #############
        for i in 1:nCells
            CFL[i] = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
        end
        maxCFL = maximum(CFL)

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)
        
        currTime += dt
    end

    return P, U, T, rho
end

function macCormack1DConservativeFDM(dx, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.2, gamma=1.4, R=287.05, Cp=1005, Cx=0.3)
    nCells = size(dx, 1)

    rho = Array{Float64, 1}(undef, nCells)
    xMom = Array{Float64, 1}(undef, nCells)
    eV2 = Array{Float64, 1}(undef, nCells)
    rhoU2p = Array{Float64, 1}(undef, nCells)
    rhoUeV2PU = Array{Float64, 1}(undef, nCells)

    for i in 1:nCells
        rho[i], xMom[i], eV2[i] = encodePrimitives(P[i], T[i], U[i])
        rhoU2p[i] = xMom[i]*U[i] + P[i]
        rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
    end
    
    drhoP = Array{Float64, 1}(undef, nCells)
    dxMP = Array{Float64, 1}(undef, nCells)
    deV2P = Array{Float64, 1}(undef, nCells)

    xMomP = Array{Float64, 1}(undef, nCells)
    eV2P = Array{Float64, 1}(undef, nCells)
    rhoP = Array{Float64, 1}(undef, nCells)
    PP = Array{Float64, 1}(undef, nCells)
    rhoU2pP = Array{Float64, 1}(undef, nCells)
    rhoUeV2PUP = Array{Float64, 1}(undef, nCells)

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end
        
        ############## Predictor #############
        dxMomdx, drhoU2pdx, drhoUeV2PU = forwardGradient(dx, xMom, rhoU2p, rhoUeV2PU)
        pCentralGrad, rhoCG, xMomCG, eV2CG = central2GradNum(dx, P, rho, xMom, eV2)
        pDenom = central2GradDenom(dx, P)[1]

        for i in 2:(nCells-1)
            # Eq. 2.99, 2.105, 2.106
            drhoP[i] = -dxMomdx[i]
            dxMP[i] = -drhoU2pdx[i]
            deV2P[i] = -drhoUeV2PU[i]

            # Predict
            S = Cx * abs(pCentralGrad[i]) / pDenom[i]
            rhoP[i] = rho[i] + drhoP[i]*dt + S*rhoCG[i]
            xMomP[i] = xMom[i] + dxMP[i]*dt + S*xMomCG[i]
            eV2P[i] = eV2[i] + deV2P[i]*dt + S*eV2CG[i]

            # Decode
            PP[i], TP, UP = decodePrimitives(rhoP[i], xMomP[i], eV2P[i])
            rhoU2pP[i] = xMomP[i]*UP + PP[i]
            rhoUeV2PUP[i] = UP*eV2P[i] + PP[i]*UP
        end

        ############### Corrector ################
        # Rearward differences to compute gradients
        dxMomdxP, drhoU2pdxP, drhoUeV2PUP = backwardGradient(dx, xMomP, rhoU2pP, rhoUeV2PUP)
        pCentralGradP, rhoCGP, xMomCGP, eV2CGP = central2GradNum(dx, PP, rhoP, xMomP, eV2P)
        pDenomP = central2GradDenom(dx, PP)[1]

        for i in 2:(nCells-1)
            drhoP2 = -dxMomdxP[i]
            dxMP2 = -drhoU2pdxP[i]
            deV2P2 = -drhoUeV2PUP[i]

            # Perform timestep using average gradients
            S = Cx * abs(pCentralGradP[i]) / pDenomP[i]
            rho[i] += (drhoP2 + drhoP[i])*dt/2 + S*rhoCGP[i]
            xMom[i] += (dxMP2 + dxMP[i])*dt/2 + S*xMomCGP[i]
            eV2[i] += (deV2P2 + deV2P[i])*dt/2 + S*eV2CGP[i]

            # Decode
            P[i], T[i], U[i] = decodePrimitives(rho[i], xMom[i], eV2[i])
            rhoU2p[i] = xMom[i]*U[i] + P[i]
            rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatment doesn't need to be good
        allVars = [ rho, rhoU2p, rhoUeV2PU, xMom, eV2, U, P, T ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells, nCells, allVars)
        
        ############## CFL Calculation, timestep adjustment #############
        for i in 1:nCells
            CFL[i] = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
        end
        maxCFL = maximum(CFL)

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)

        currTime += dt
    end

    return P, U, T, rho
end

# U is a vector for FVM
function upwindFVM(mesh, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.2, gamma=1.4, R=287.05, Cp=1005)
    nCells = size(dx, 1)

    # State variables, values are the averages/cell center values
    rho = Array{Float64, 1}(undef, nCells)
    xMom = Array{Float64, 1}(undef, nCells)
    eV2 = Array{Float64, 1}(undef, nCells)
    # Flux variables for equations 2 and 3 (xMom is flux variable for the continuity eqn)
    rhoU2p = Array{Float64, 1}(undef, nCells)
    rhoUeV2PU = Array{Float64, 1}(undef, nCells)

    # Calc state and flux variables from primitives
    for i in 1:nCells
        rho[i], xMom[i], eV2[i] = encodePrimitives(P[i], T[i], U[i])
        rhoU2p[i] = xMom[i]*U[i] + P[i]
        rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
    end

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end
        
        ############## Predictor #############
        dxMomdx, drhoU2pdx, drhoUeV2PU = upwindGradient(dx, U, xMom, rhoU2p, rhoUeV2PU)

        for i in 2:(nCells-1)
            # Eq. 2.99, 2.105, 2.106
            drhoP[i] = -dxMomdx[i]
            dxMP[i] = -drhoU2pdx[i]
            deV2P[i] = -drhoUeV2PU[i]

            # Timestep
            rho[i] = rho[i] + drhoP[i]*dt
            xMom[i] = xMom[i] + dxMP[i]*dt
            eV2[i] = eV2[i] + deV2P[i]*dt

            # Decode
            P[i], T[i], U[i] = decodePrimitives(rho[i], xMom[i], eV2[i])
            rhoU2p[i] = xMom[i]*U[i] + P[i]
            rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatment doesn't need to be good
        allVars = [ rho, rhoU2p, rhoUeV2PU, xMom, eV2, U, P, T ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells, nCells, allVars)
        
        ############## CFL Calculation, timestep adjustment #############
        maxCFL = 0
        for i in 1:nCells
            CFL = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
            maxCFL = max(CFL, maxCFL)
        end

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)

        currTime += dt
    end

    return P, U, T, rho
end

################## Output ##################
nCells = 500
P, U, T, rho = macCormack1DFDM(initializeShockTubeFDM(nCells)..., initDt=0.00000001, endTime=0.1427)
# P, U, T, rho = macCormack1D(initializeShockTube(nCells)..., initDt=0.00000001, endTime=0.1)
plotShockTubeResults(P, U, T, rho)