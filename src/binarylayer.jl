# BinaryLayer and BinaryMERA types, and methods thereof.
# To be `included` in MERA.jl.

# # # The core stuff

# Index numbering convention is as follows, where the physical indices are at the bottom:
# Disentangler:
#  3|   4|
#  +------+
#  |  u   |
#  +------+
#  1|   2|
#
# Isometry:
#    3|
#  +------+
#  |  w   |
#  +------+
#  1|   2|

struct BinaryLayer <: SimpleLayer
    disentangler
    isometry
end

BinaryMERA = GenericMERA{BinaryLayer}

# Implement the iteration and indexing interfaces. Allows things like `u, w = layer`.
Base.iterate(layer::BinaryLayer) = (layer.disentangler, 1)
Base.iterate(layer::BinaryLayer, state) = state == 1 ? (layer.isometry, 2) : nothing
Base.eltype(::Type{BinaryLayer}) = TensorMap
Base.length(layer::BinaryLayer) = 2
Base.firstindex(layer::BinaryLayer) = 1
Base.lastindex(layer::BinaryLayer) = 2
function Base.getindex(layer::BinaryLayer, i)
    i == 1 && return layer.disentangler
    i == 2 && return layer.isometry
    throw(BoundsError(layer, i))
end

"""
The ratio by which the number of sites changes when go down through this layer.
"""
scalefactor(::Type{BinaryMERA}) = 2

get_disentangler(m::BinaryMERA, depth) = get_layer(m, depth).disentangler
get_isometry(m::BinaryMERA, depth) = get_layer(m, depth).isometry

function set_disentangler!(m::BinaryMERA, u, depth; kwargs...)
    w = get_isometry(m, depth)
    return set_layer!(m, (u, w), depth; kwargs...)
end

function set_isometry!(m::BinaryMERA, w, depth; kwargs...)
    u = get_disentangler(m, depth)
    return set_layer!(m, (u, w), depth; kwargs...)
end

causal_cone_width(::Type{BinaryLayer}) = 3

outputspace(layer::BinaryLayer) = space(layer.disentangler, 1)
inputspace(layer::BinaryLayer) = space(layer.isometry, 3)'

"""
Return a new layer where the isometries have been padded with zeros to change the input
(top) vector space to be V_new.
"""
function expand_inputspace(layer::BinaryLayer, V_new)
    u, w = layer
    w = pad_with_zeros_to(w, 3 => V_new')
    return BinaryLayer(u, w)
end

"""
Return a new layer where the disentanglers and isometries have been padded with zeros to
change the output (bottom) vector space to be V_new.
"""
function expand_outputspace(layer::BinaryLayer, V_new)
    u, w = layer
    u = pad_with_zeros_to(u, 1 => V_new, 2 => V_new, 3 => V_new', 4 => V_new')
    w = pad_with_zeros_to(w, 1 => V_new, 2 => V_new)
    return BinaryLayer(u, w)
end

"""
Return a layer with random tensors, with `Vin` and `Vout` as the input and output spaces.
If `random_disentangler=true`, the disentangler is also a random unitary, if `false`
(default), it is the identity.
"""
function randomlayer(::Type{BinaryLayer}, Vin, Vout; random_disentangler=false,
                     T=ComplexF64)
    ufunc(o, i) = (random_disentangler ?
                   randomisometry(o, i, T) :
                   T <: Complex ? complex(isomorphism(o, i)) : isomorphism(o, i))
    u = ufunc(Vout ⊗ Vout, Vout ⊗ Vout)
    w = randomisometry(Vout ⊗ Vout, Vin)
    return BinaryLayer(u, w)
end

# # # Stiefel manifold functions

function stiefel_gradient(h, rho, layer::BinaryLayer, pars; vary_disentanglers=true)
    if vary_disentanglers
        uenv = environment_disentangler(h, layer, rho)
    else
        # TODO We could save some subleading computations by not running the whole machinery
        # when uenv .== 0, but this implementation is much simpler.
        V = outputspace(layer)
        uenv = TensorMap(zeros, eltype(layer), V ⊗ V ← V ⊗ V)
    end
    wenv = environment_isometry(h, layer, rho)
    u, w = layer
    # The environment is the partial derivative. We need to turn that into a tangent vector
    # of the Stiefel manifold point u or w.
    if pars[:metric] === :canonical
        projection = stiefel_projection_canonical
    elseif pars[:metric] === :euclidean
        projection = stiefel_projection_euclidean
    end
    ugrad = projection(u, uenv)
    wgrad = projection(w, wenv)
    return BinaryLayer(ugrad, wgrad)
end

function stiefel_geodesic(l::BinaryLayer, ltan::BinaryLayer, alpha::Number)
    u, utan = stiefel_geodesic_unitary(l.disentangler, ltan.disentangler, alpha)
    w, wtan = stiefel_geodesic_isometry(l.isometry, ltan.isometry, alpha)
    return BinaryLayer(u, w), BinaryLayer(utan, wtan)
end

# # # Invariants

"""
Check the compatibility of the legs connecting the disentanglers and the isometries.
Return true/false.
"""
function space_invar_intralayer(layer::BinaryLayer)
    u, w = layer
    matching_bonds = [(space(u, 3)', space(w, 2)),
                      (space(u, 4)', space(w, 1))]
    allmatch = all([==(pair...) for pair in matching_bonds])
    return allmatch
end

"""
Check the compatibility of the legs connecting the isometries of the first layer to the
disentanglers of the layer above it. Return true/false.
"""
function space_invar_interlayer(layer::BinaryLayer, next_layer::BinaryLayer)
    u, w = layer.disentangler, layer.isometry
    unext, wnext = next_layer.disentangler, next_layer.isometry
    matching_bonds = [(space(w, 3)', space(unext, 1)),
                      (space(w, 3)', space(unext, 2))]
    allmatch = all([==(pair...) for pair in matching_bonds])
    return allmatch
end

# # # Ascending and descending superoperators

"""
Ascend a threesite `op` from the bottom of the given layer to the top.
"""
function ascend(op::SquareTensorMap{3}, layer::BinaryLayer, pos=:avg)
    u, w = layer
    if in(pos, (:left, :l, :L))
        @tensor(
                scaled_op[-100 -200 -300; -400 -500 -600] :=
                w[5 6; -400] * w[9 8; -500] * w[16 15; -600] *
                u[1 2; 6 9] * u[10 12; 8 16] *
                op[3 4 14; 1 2 10] *
                u'[7 13; 3 4] * u'[11 17; 14 12] *
                w'[-100; 5 7] * w'[-200; 13 11] * w'[-300; 17 15]
               )
    elseif in(pos, (:right, :r, :R))
        @tensor(
                scaled_op[-100 -200 -300; -400 -500 -600] :=
                w[15 16; -400] * w[8 9; -500] * w[6 5; -600] *
                u[12 10; 16 8] * u[1 2; 9 6] *
                op[14 3 4; 10 1 2] *
                u'[17 11; 12 14] * u'[13 7; 3 4] *
                w'[-100; 15 17] * w'[-200; 11 13] * w'[-300; 7 5]
               )
    elseif in(pos, (:a, :avg, :average))
        l = ascend(op, layer, :left)
        r = ascend(op, layer, :right)
        scaled_op = (l+r)/2.
    else
        throw(ArgumentError("Unknown position (should be :l, :r, or :avg)."))
    end
    return scaled_op
end


# TODO Would there be a nice way of doing this where I wouldn't have to replicate all the
# network contractions? @ncon could do it, but Jutho's testing says it's significantly
# slower. This is only used for diagonalizing in charge sectors, so having tensors with
# non-trivial charge would also solve this.
"""
Ascend a threesite `op` with an extra free leg from the bottom of the given layer to the
top.
"""
function ascend(op::TensorMap{S1,3,4}, layer::BinaryLayer, pos=:avg) where {S1}
    u, w = layer
    if in(pos, (:left, :l, :L))
        @tensor(
                scaled_op[-100 -200 -300; -400 -500 -600 -1000] :=
                w[5 6; -400] * w[9 8; -500] * w[16 15; -600] *
                u[1 2; 6 9] * u[10 12; 8 16] *
                op[3 4 14; 1 2 10 -1000] *
                u'[7 13; 3 4] * u'[11 17; 14 12] *
                w'[-100; 5 7] * w'[-200; 13 11] * w'[-300; 17 15]
               )
    elseif in(pos, (:right, :r, :R))
        @tensor(
                scaled_op[-100 -200 -300; -400 -500 -600 -1000] :=
                w[15 16; -400] * w[8 9; -500] * w[6 5; -600] *
                u[12 10; 16 8] * u[1 2; 9 6] *
                op[14 3 4; 10 1 2 -1000] *
                u'[17 11; 12 14] * u'[13 7; 3 4] *
                w'[-100; 15 17] * w'[-200; 11 13] * w'[-300; 7 5]
               )
    elseif in(pos, (:a, :avg, :average))
        l = ascend(op, layer, :left)
        r = ascend(op, layer, :right)
        scaled_op = (l+r)/2.
    else
        throw(ArgumentError("Unknown position (should be :l, :r, or :avg)."))
    end
    return scaled_op
end

function ascend(op::SquareTensorMap{2}, layer::BinaryLayer, pos=:avg)
    op = expand_support(op, causal_cone_width(BinaryLayer))
    return ascend(op, layer, pos)
end

function ascend(op::SquareTensorMap{1}, layer::BinaryLayer, pos=:avg)
    op = expand_support(op, causal_cone_width(BinaryLayer))
    return ascend(op, layer, pos)
end

"""
Decend a threesite `rho` from the top of the given layer to the bottom.
"""
function descend(rho::SquareTensorMap{3}, layer::BinaryLayer, pos=:avg)
    u, w = layer
    if in(pos, (:left, :l, :L))
        @tensor(
                scaled_rho[-100 -200 -300; -400 -500 -600] :=
                u'[16 17; -400 -500] * u'[2 10; -600 11] *
                w'[12; 1 16] * w'[9; 17 2] * w'[5; 10 4] *
                rho[13 7 6; 12 9 5] *
                w[1 14; 13] * w[15 3; 7] * w[8 4; 6] *
                u[-100 -200; 14 15] * u[-300 11; 3 8]
               )
    elseif in(pos, (:right, :r, :R))
        @tensor(
                scaled_rho[-100 -200 -300; -400 -500 -600] :=
                u'[10 2; 11 -400] * u'[17 16; -500 -600] *
                w'[5; 4 10] * w'[9; 2 17] * w'[12; 16 1] *
                rho[6 7 13; 5 9 12] *
                w[4 8; 6] * w[3 15; 7] * w[14 1; 13] *
                u[11 -100; 8 3] * u[-200 -300; 15 14]
               )
    elseif in(pos, (:a, :avg, :average))
        l = descend(rho, layer, :left)
        r = descend(rho, layer, :right)
        scaled_rho = (l+r)/2.
    else
        throw(ArgumentError("Unknown position (should be :l, :r, or :avg)."))
    end
    return scaled_rho
end

# # # Optimization

"""
Loop over the tensors of the layer, optimizing each one in turn to minimize the expecation
value of `h`. `rho` is the density matrix right above this layer.

Three parameters are expected to be in the dictionary `pars`:
    :layer_iters, for how many times to loop over the tensors within a layer,
    :disentangler_iters, for how many times to loop over the disentangler,
    :isometry_iters, for how many times to loop over the isometry.
"""
function minimize_expectation_ev(h, layer::BinaryLayer, rho, pars; vary_disentanglers=true)
    gradnorm_u, gradnorm_w = 0.0, 0.0
    for i in 1:pars[:layer_iters]
        if vary_disentanglers
            for j in 1:pars[:disentangler_iters]
                layer, gradnorm_u = minimize_expectation_ev_disentangler(h, layer, rho)
            end
        end
        for j in 1:pars[:isometry_iters]
            layer, gradnorm_w = minimize_expectation_ev_isometry(h, layer, rho)
        end
    end
    # We use the last values of gradnorms for u and w to compute this. That's the closest
    # thing to having the gradient norm at the endpoint.
    gradnorm = sqrt(gradnorm_u^2 + gradnorm_w^2)
    return layer, gradnorm
end

"""
Return a new layer, where the disentangler has been changed to the locally optimal one to
minimize the expectation of a threesite operator `h`.
"""
function minimize_expectation_ev_disentangler(h, layer::BinaryLayer, rho)
    uold, wold = layer
    env = environment_disentangler(h, layer, rho)
    U, S, Vt = tsvd(env, (1,2), (3,4))
    u = U * Vt
    # Compute the Stiefel manifold norm of the gradient. Used as a convergence measure.
    uoldenv = uold' * env
    @tensor crossterm[] := uoldenv[1 2; 3 4] * uoldenv[3 4; 1 2]
    gradnorm = sqrt(abs(norm(env)^2 - real(TensorKit.scalar(crossterm))))
    return BinaryLayer(u, wold), gradnorm
end

"""
Return the environment for a disentangler.
"""
function environment_disentangler(h::SquareTensorMap{3}, layer::BinaryLayer, rho)
    u, w = layer
    @tensor(
            env1[-1 -2; -3 -4] :=
            rho[15 14 9; 17 18 10] *
            w[5 6; 15] * w[16 -3; 14] * w[-4 8; 9] *
            u[1 2; 6 16] *
            h[3 4 13; 1 2 -1] *
            u'[7 12; 3 4] * u'[11 19; 13 -2] *
            w'[17; 5 7] * w'[18; 12 11] * w'[10; 19 8]
           )
                
    @tensor(
            env2[-1 -2; -3 -4] :=
            rho[3 10 5; 4 15 6] *
            w[1 11; 3] * w[9 -3; 10] * w[-4 2; 5] *
            u[12 19; 11 9] *
            h[18 7 8; 19 -1 -2] *
            u'[13 14; 12 18] * u'[16 17; 7 8] *
            w'[4; 1 13] * w'[15; 14 16] * w'[6; 17 2]
           )
                
    @tensor(
            env3[-1 -2; -3 -4] :=
            rho[5 10 3; 6 15 4] *
            w[2 -3; 5] * w[-4 9; 10] * w[11 1; 3] *
            u[19 12; 9 11] *
            h[8 7 18; -1 -2 19] *
            u'[17 16; 8 7] * u'[14 13; 18 12] *
            w'[6; 2 17] * w'[15; 16 14] * w'[4; 13 1]
           )

    @tensor(
            env4[-1 -2; -3 -4] :=
            rho[9 14 15; 10 18 17] *
            w[8 -3; 9] * w[-4 16; 14] * w[6 5; 15] *
            u[2 1; 16 6] *
            h[13 4 3; -2 2 1] *
            u'[19 11; -1 13] * u'[12 7; 4 3] *
            w'[10; 8 19] * w'[18; 11 12] * w'[17; 7 5]
           )

    env = (env1 + env2 + env3 + env4)/2
    # Complex conjugate.
    env = permute(env', (3,4), (1,2))
    return env
end

function environment_disentangler(h::SquareTensorMap{2}, layer::BinaryLayer, rho)
    h = expand_support(h, causal_cone_width(BinaryLayer))
    return environment_disentangler(h, layer, rho)
end

function environment_disentangler(h::SquareTensorMap{1}, layer::BinaryLayer, rho)
    h = expand_support(h, causal_cone_width(BinaryLayer))
    return environment_disentangler(h, layer, rho)
end

"""
Return a new layer, where the isometry has been changed to the locally optimal one to
minimize the expectation of a threesite operator `h`.
"""
function minimize_expectation_ev_isometry(h, layer::BinaryLayer, rho)
    uold, wold = layer
    env = environment_isometry(h, layer, rho)
    U, S, Vt = tsvd(env, (1,2), (3,))
    w = U * Vt
    # Compute the Stiefel manifold norm of the gradient. Used as a convergence measure.
    woldenv = wold' * env
    @tensor crossterm[] := woldenv[1; 2] * woldenv[2; 1]
    gradnorm = sqrt(abs(norm(env)^2 - real(TensorKit.scalar(crossterm))))
    return BinaryLayer(uold, w), gradnorm
end

"""
Return the environment for the isometry.
"""
function environment_isometry(h::SquareTensorMap{3}, layer, rho)
    u, w = layer
    @tensor(
            env1[-1 -2; -3] :=
            rho[18 17 -3; 16 15 19] *
            w[5 6; 18] * w[9 8; 17] *
            u[2 1; 6 9] * u[10 11; 8 -1] *
            h[4 3 12; 2 1 10] *
            u'[7 14; 4 3] * u'[13 20; 12 11] *
            w'[16; 5 7] * w'[15; 14 13] * w'[19; 20 -2]
           )
                
    @tensor(
            env2[-1 -2; -3] :=
            rho[16 15 -3; 18 17 19] *
            w[12 13; 16] * w[5 6; 15] *
            u[9 7; 13 5] * u[2 1; 6 -1] *
            h[8 4 3; 7 2 1] *
            u'[14 11; 9 8] * u'[10 20; 4 3] *
            w'[18; 12 14] * w'[17; 11 10] * w'[19; 20 -2]
           )

    @tensor(
            env3[-1 -2; -3] :=
            rho[18 -3 14; 19 20 15] *
            w[5 6; 18] * w[17 13; 14] *
            u[2 1; 6 -1] * u[12 11; -2 17] *
            h[4 3 9; 2 1 12] *
            u'[7 10; 4 3] * u'[8 16; 9 11] *
            w'[19; 5 7] * w'[20; 10 8] * w'[15; 16 13]
           )

    @tensor(
            env4[-1 -2; -3] :=
            rho[14 -3 18; 15 20 19] *
            w[13 17; 14] * w[6 5; 18] *
            u[11 12; 17 -1] * u[1 2; -2 6] *
            h[9 3 4; 12 1 2] *
            u'[16 8; 11 9] * u'[10 7; 3 4] *
            w'[15; 13 16] * w'[20; 8 10] * w'[19; 7 5]
           )

    @tensor(
            env5[-1 -2; -3] :=
            rho[-3 15 16; 19 17 18] *
            w[6 5; 15] * w[13 12; 16] *
            u[1 2; -2 6] * u[7 9; 5 13] *
            h[3 4 8; 1 2 7] *
            u'[20 10; 3 4] * u'[11 14; 8 9] *
            w'[19; -1 20] * w'[17; 10 11] * w'[18; 14 12]
           )

    @tensor(
            env6[-1 -2; -3] :=
            rho[-3 17 18; 19 15 16] *
            w[8 9; 17] * w[6 5; 18] *
            u[11 10; -2 8] * u[1 2; 9 6] *
            h[12 3 4; 10 1 2] *
            u'[20 13; 11 12] * u'[14 7; 3 4] *
            w'[19; -1 20] * w'[15; 13 14] * w'[16; 7 5]
           )

    env = (env1 + env2 + env3 + env4 + env5 + env6)/2
    # Complex conjugate.
    env = permute(env', (2,3), (1,))
    return env
end

function environment_isometry(h::SquareTensorMap{2}, layer::BinaryLayer, rho)
    h = expand_support(h, causal_cone_width(BinaryLayer))
    return environment_isometry(h, layer, rho)
end

function environment_isometry(h::SquareTensorMap{1}, layer::BinaryLayer, rho)
    h = expand_support(h, causal_cone_width(BinaryLayer))
    return environment_isometry(h, layer, rho)
end

