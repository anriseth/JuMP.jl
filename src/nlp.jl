#  Copyright 2015, Iain Dunning, Joey Huchette, Miles Lubin, and contributors
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.

immutable NonlinearExpression
    m::Model
    index::Int
end

include("nlpmacros.jl")

import DualNumbers: Dual, epsilon

type NonlinearExprData
    nd::Vector{NodeData}
    const_values::Vector{Float64}
end

typealias NonlinearConstraint GenericRangeConstraint{NonlinearExprData}

type NLPData
    nlobj
    nlconstr::Vector{NonlinearConstraint}
    nlexpr::Vector{NonlinearExprData}
    nlconstrDuals::Vector{Float64}
    evaluator
end

function NonlinearExpression(m::Model,ex::NonlinearExprData)
    initNLP(m)
    nldata::NLPData = m.nlpdata
    push!(nldata.nlexpr, ex)
    return NonlinearExpression(m, length(nldata.nlexpr))
end

NLPData() = NLPData(nothing, NonlinearConstraint[], NonlinearExprData[], Float64[], nothing)

Base.copy(::NLPData) = error("Copying nonlinear problems not yet implemented")

function initNLP(m::Model)
    if m.nlpdata === nothing
        m.nlpdata = NLPData()
    end
end

function getDual(c::ConstraintRef{NonlinearConstraint})
    initNLP(c.m)
    nldata::NLPData = c.m.nlpdata
    if length(nldata.nlconstrDuals) != length(nldata.nlconstr)
        error("Dual solution not available. Check that the model was properly solved.")
    end
    return nldata.nlconstrDuals[c.idx]
end

type FunctionStorage
    nd::Vector{NodeData}
    adj::SparseMatrixCSC{Bool,Int}
    const_values::Vector{Float64}
    forward_storage::Vector{Float64}
    reverse_storage::Vector{Float64}
    grad_sparsity::Vector{Int}
    hess_I::Vector{Int} # nonzero pattern of hessian
    hess_J::Vector{Int}
    rinfo::Coloring.RecoveryInfo # coloring info for hessians
    seed_matrix::Matrix{Float64}
    linearity::Linearity
    dependent_subexpressions::Vector{Int} # subexpressions which this function depends on, ordered for forward pass
end

type SubexpressionStorage
    nd::Vector{NodeData}
    adj::SparseMatrixCSC{Bool,Int}
    const_values::Vector{Float64}
    forward_storage::Vector{Float64}
    reverse_storage::Vector{Float64}
end

type JuMPNLPEvaluator <: MathProgBase.AbstractNLPEvaluator
    m::Model
    A::SparseMatrixCSC{Float64,Int} # linear constraint matrix
    has_nlobj::Bool
    linobj::Vector{Float64}
    objective::FunctionStorage
    constraints::Vector{FunctionStorage}
    subexpressions::Vector{SubexpressionStorage}
    subexpression_order::Vector{Int}
    subexpression_forward_values::Vector{Float64}
    subexpression_reverse_values::Vector{Float64}
    last_x::Vector{Float64}
    jac_storage::Vector{Float64} # temporary storage for computing jacobians
    # storage for computing hessians
    want_hess::Bool
    forward_storage_hess::Vector{Dual{Float64}} # length is of the longest expression
    reverse_storage_hess::Vector{Dual{Float64}} # length is of the longest expression
    forward_input_vector::Vector{Dual{Float64}} # length is number of variables
    reverse_output_vector::Vector{Dual{Float64}}# length is number of variables
    # timers
    eval_f_timer::Float64
    eval_g_timer::Float64
    eval_grad_f_timer::Float64
    eval_jac_g_timer::Float64
    eval_hesslag_timer::Float64
    function JuMPNLPEvaluator(m::Model)
        d = new(m)
        numVar = m.numCols
        d.A = prepConstrMatrix(m)
        d.constraints = FunctionStorage[]
        d.last_x = fill(NaN, numVar)
        d.jac_storage = Array(Float64,numVar)
        d.forward_input_vector = Array(Dual{Float64},numVar)
        d.reverse_output_vector = Array(Dual{Float64},numVar)
        d.eval_f_timer = 0
        d.eval_g_timer = 0
        d.eval_grad_f_timer = 0
        d.eval_jac_g_timer = 0
        d.eval_hesslag_timer = 0
        return d
    end
end

function FunctionStorage(nld::NonlinearExprData,numVar, want_hess::Bool, subexpr::Vector{Vector{NodeData}}, dependent_subexpressions)

    nd = nld.nd
    const_values = nld.const_values
    adj = adjmat(nd)
    forward_storage = zeros(length(nd))
    reverse_storage = zeros(length(nd))
    grad_sparsity = compute_gradient_sparsity(nd)

    for k in dependent_subexpressions
        union!(grad_sparsity, compute_gradient_sparsity(subexpr[k]))
    end

    if want_hess
        # compute hessian sparsity
        linearity = classify_linearity(nd, adj)
        edgelist = compute_hessian_sparsity(nd, adj, linearity)
        hess_I, hess_J, rinfo = Coloring.hessian_color_preprocess(edgelist, numVar)
        seed_matrix = Coloring.seed_matrix(rinfo)
    else
        hess_I = hess_J = Int[]
        rinfo = Coloring.RecoveryInfo()
        seed_matrix = Array(Float64,0,0)
        linearity = [NONLINEAR]
    end

    return FunctionStorage(nd, adj, const_values, forward_storage, reverse_storage, sort(collect(grad_sparsity)), hess_I, hess_J, rinfo, seed_matrix, linearity[1],dependent_subexpressions)

end

function SubexpressionStorage(nld::NonlinearExprData,numVar, want_hess::Bool)

    nd = nld.nd
    const_values = nld.const_values
    adj = adjmat(nd)
    forward_storage = zeros(length(nd))
    reverse_storage = zeros(length(nd))

    if want_hess
        error()
    end

    return SubexpressionStorage(nd, adj, const_values, forward_storage, reverse_storage)

end

function MathProgBase.initialize(d::JuMPNLPEvaluator, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac, :Hess, :HessVec, :ExprGraph])
            error("Unsupported feature $feat")
            # TODO: implement Jac-vec products
            # for solvers that need them
        end
    end
    if d.eval_f_timer != 0
        # we've already been initialized
        # assume no new features are being requested.
        return
    end

    initNLP(d.m) #in case the problem is purely linear/quadratic thus far
    nldata::NLPData = d.m.nlpdata

    if :ExprGraph in requested_features
        error("Not supported yet")
        if length(requested_features) == 1 # don't need to do anything else
            return
        end
    end

    tic()

    d.linobj, linrowlb, linrowub = prepProblemBounds(d.m)
    numVar = length(d.linobj)

    d.want_hess = (:Hess in requested_features)
    @assert !d.want_hess

    d.has_nlobj = isa(nldata.nlobj, NonlinearExprData)
    max_expr_length = 0
    main_expressions = Array(Vector{NodeData},0)
    subexpr = Array(Vector{NodeData},0)
    for nlexpr in nldata.nlexpr
        push!(subexpr, nlexpr.nd)
    end
    if d.has_nlobj
        push!(main_expressions,nldata.nlobj.nd)
    end
    for nlconstr in nldata.nlconstr
        push!(main_expressions,nlconstr.terms.nd)
    end
    println("Ordering subexpressions")
    @time d.subexpression_order, individual_order = order_subexpressions(main_expressions,subexpr)
    if d.has_nlobj
        @assert length(d.m.obj.qvars1) == 0 && length(d.m.obj.aff.vars) == 0
        d.objective = FunctionStorage(nldata.nlobj, numVar, d.want_hess, subexpr, individual_order[1])
        max_expr_length = max(max_expr_length, length(d.objective.nd))
    end

    for k in 1:length(nldata.nlconstr)
        nlconstr = nldata.nlconstr[k]
        idx = (d.has_nlobj) ? k+1 : k
        push!(d.constraints, FunctionStorage(nlconstr.terms, numVar, d.want_hess, subexpr, individual_order[idx]))
        max_expr_length = max(max_expr_length, length(d.constraints[end].nd))
    end

    if d.want_hess # allocate extra storage
        d.forward_storage_hess = Array(Dual{Float64},max_expr_length)
        d.reverse_storage_hess = Array(Dual{Float64},max_expr_length)
    end

    # order subexpressions



    d.subexpressions = Array(SubexpressionStorage, length(nldata.nlexpr))
    for k in d.subexpression_order # only load expressions which actually are used
        d.subexpressions[k] = SubexpressionStorage(nldata.nlexpr[k], numVar, d.want_hess)
    end
    d.subexpression_forward_values = Array(Float64, length(d.subexpressions))
    d.subexpression_reverse_values = Array(Float64, length(d.subexpressions))



    tprep = toq()
    println("Prep time: $tprep")

    # reset timers
    d.eval_f_timer = 0
    d.eval_grad_f_timer = 0
    d.eval_g_timer = 0
    d.eval_jac_g_timer = 0
    d.eval_hesslag_timer = 0

    nothing
end

MathProgBase.features_available(d::JuMPNLPEvaluator) = [:Grad, :Jac]#, :Hess, :HessVec, :ExprGraph]

function forward_eval_all(d::JuMPNLPEvaluator,x)
    # do a forward pass on all expressions at x
    subexpr_values = d.subexpression_forward_values
    for k in d.subexpression_order
        ex = d.subexpressions[k]
        subexpr_values[k] = forward_eval(ex.forward_storage,ex.nd,ex.adj,ex.const_values,x,subexpr_values)
    end
    if d.has_nlobj
        ex = d.objective
        forward_eval(ex.forward_storage,ex.nd,ex.adj,ex.const_values,x,subexpr_values)
    end
    for ex in d.constraints
        forward_eval(ex.forward_storage,ex.nd,ex.adj,ex.const_values,x,subexpr_values)
    end
    copy!(d.last_x,x)
end

function MathProgBase.eval_f(d::JuMPNLPEvaluator, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
    end
    val = zero(eltype(x))
    if d.has_nlobj
        val = d.objective.forward_storage[1]
    else
        qobj = d.m.obj::QuadExpr
        val = dot(x,d.linobj) + qobj.aff.constant
        for k in 1:length(qobj.qvars1)
            val += qobj.qcoeffs[k]*x[qobj.qvars1[k].col]*x[qobj.qvars2[k].col]
        end
    end
    d.eval_f_timer += toq()
    return val
end

function MathProgBase.eval_grad_f(d::JuMPNLPEvaluator, g, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
    end
    if d.has_nlobj
        fill!(g,0.0)
        ex = d.objective
        subexpr_reverse_values = d.subexpression_reverse_values
        subexpr_reverse_values[ex.dependent_subexpressions] = 0.0
        reverse_eval(g,ex.reverse_storage,ex.forward_storage,ex.nd,ex.adj,ex.const_values,subexpr_reverse_values)
        for i in length(ex.dependent_subexpressions):-1:1
            k = ex.dependent_subexpressions[i]
            subexpr = d.subexpressions[k]
            reverse_eval(g,subexpr.reverse_storage,subexpr.forward_storage,subexpr.nd,subexpr.adj,subexpr.const_values,subexpr_reverse_values,subexpr_reverse_values[k])

        end
    else
        copy!(g,d.linobj)
        qobj::QuadExpr = d.m.obj
        for k in 1:length(qobj.qvars1)
            coef = qobj.qcoeffs[k]
            g[qobj.qvars1[k].col] += coef*x[qobj.qvars2[k].col]
            g[qobj.qvars2[k].col] += coef*x[qobj.qvars1[k].col]
        end
    end
    d.eval_grad_f_timer += toq()
    return
end

function MathProgBase.eval_g(d::JuMPNLPEvaluator, g, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
    end
    A = d.A
    for i in 1:size(A,1); g[i] = 0.0; end
    #fill!(sub(g,1:size(A,1)), 0.0)
    A_mul_B!(sub(g,1:size(A,1)),A,x)
    idx = size(A,1)+1
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c::QuadConstraint in quadconstr
        aff = c.terms.aff
        v = aff.constant
        for k in 1:length(aff.vars)
            v += aff.coeffs[k]*x[aff.vars[k].col]
        end
        for k in 1:length(c.terms.qvars1)
            v += c.terms.qcoeffs[k]*x[c.terms.qvars1[k].col]*x[c.terms.qvars2[k].col]
        end
        g[idx] = v
        idx += 1
    end
    for ex in d.constraints
        g[idx] = ex.forward_storage[1]
        idx += 1
    end

    d.eval_g_timer += toq()
    #print("x = ");show(x);println()
    #println(size(A,1), " g(x) = ");show(g);println()
    return
end

function MathProgBase.eval_jac_g(d::JuMPNLPEvaluator, J, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
    end
    fill!(J,0.0)
    idx = 1
    A = d.A
    for col = 1:size(A,2)
        for pos = nzrange(A,col)
            J[idx] = A.nzval[pos]
            idx += 1
        end
    end
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c::QuadConstraint in quadconstr
        aff = c.terms.aff
        for k in 1:length(aff.vars)
            J[idx] = aff.coeffs[k]
            idx += 1
        end
        for k in 1:length(c.terms.qvars1)
            coef = c.terms.qcoeffs[k]
            qidx1 = c.terms.qvars1[k].col
            qidx2 = c.terms.qvars2[k].col

            J[idx] = coef*x[qidx2]
            J[idx+1] = coef*x[qidx1]
            idx += 2
        end
    end
    grad_storage = d.jac_storage
    subexpr_reverse_values = d.subexpression_reverse_values
    for ex in d.constraints
        nzidx = ex.grad_sparsity
        grad_storage[nzidx] = 0.0
        subexpr_reverse_values[ex.dependent_subexpressions] = 0.0

        reverse_eval(grad_storage,ex.reverse_storage,ex.forward_storage,ex.nd,ex.adj,ex.const_values,subexpr_reverse_values)
        for i in length(ex.dependent_subexpressions):-1:1
            k = ex.dependent_subexpressions[i]
            subexpr = d.subexpressions[k]
            reverse_eval(grad_storage,subexpr.reverse_storage,subexpr.forward_storage,subexpr.nd,subexpr.adj,subexpr.const_values,subexpr_reverse_values,subexpr_reverse_values[k])
        end

        for k in 1:length(nzidx)
            J[idx+k-1] = grad_storage[nzidx[k]]
        end
        idx += length(nzidx)
    end

    d.eval_jac_g_timer += toq()
    #print("x = ");show(x);println()
    #print("V ");show(J);println()
    return
end


#=
function MathProgBase.eval_hesslag_prod(
    d::JuMPNLPEvaluator,
    h::Vector{Float64}, # output vector
    x::Vector{Float64}, # current solution
    v::Vector{Float64}, # rhs vector
    σ::Float64,         # multiplier for objective
    μ::Vector{Float64}) # multipliers for each constraint

    nldata = d.m.nlpdata::NLPData

    # evaluate directional derivative of the gradient
    dualvec = reinterpret(Dual{Float64}, nldata.nlconstrlist.dualvec)
    dualout = reinterpret(Dual{Float64}, nldata.nlconstrlist.dualout)
    @assert length(dualvec) >= length(x)
    for i in 1:length(x)
        dualvec[i] = Dual(x[i], v[i])
        dualout[i] = zero(Dual{Float64})
    end
    MathProgBase.eval_grad_f(d, dualout, dualvec)
    for i in 1:length(x)
        h[i] = σ*epsilon(dualout[i])
    end

    row = size(d.A,1)+1
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c in quadconstr
        l = μ[row]
        for k in 1:length(c.terms.qvars1)
            col1 = c.terms.qvars1[k].col
            col2 = c.terms.qvars2[k].col
            coef = c.terms.qcoeffs[k]
            if col1 == col2
                h[col1] += l*2*coef*v[col1]
            else
                h[col1] += l*coef*v[col2]
                h[col2] += l*coef*v[col1]
            end
        end
        row += 1
    end

    ReverseDiffSparse.eval_hessvec!(h, v, nldata.nlconstrlist, x, subarr(μ,row:length(μ)))

end=#

function MathProgBase.eval_hesslag(
    d::JuMPNLPEvaluator,
    H::Vector{Float64},         # Sparse hessian entry vector
    x::Vector{Float64},         # Current solution
    obj_factor::Float64,        # Lagrangian multiplier for objective
    lambda::Vector{Float64})    # Multipliers for each constraint

    qobj = d.m.obj::QuadExpr
    nldata = d.m.nlpdata::NLPData

    d.want_hess || error("Hessian computations were not requested on the call to MathProgBase.initialize.")

    tic()

    # quadratic objective
    nzcount = 1
    for k in 1:length(qobj.qvars1)
        if qobj.qvars1[k].col == qobj.qvars2[k].col
            H[nzcount] = obj_factor*2*qobj.qcoeffs[k]
        else
            H[nzcount] = obj_factor*qobj.qcoeffs[k]
        end
        nzcount += 1
    end
    # quadratic constraints
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for i in 1:length(quadconstr)
        c = quadconstr[i]
        l = lambda[length(d.m.linconstr)+i]
        for k in 1:length(c.terms.qvars1)
            if c.terms.qvars1[k].col == c.terms.qvars2[k].col
                H[nzcount] = l*2*c.terms.qcoeffs[k]
            else
                H[nzcount] = l*c.terms.qcoeffs[k]
            end
            nzcount += 1
        end
    end

    for i in 1:length(x)
        d.forward_input_vector[i] = Dual(x[i],0.0)
    end
    recovery_tmp_storage = reinterpret(Float64, d.reverse_output_vector)
    nzcount -= 1

    if d.has_nlobj
        ex = d.objective
        nzthis = hessian_slice(d, ex, x, H, obj_factor, nzcount, recovery_tmp_storage)
        nzcount += nzthis
    end

    for i in 1:length(d.constraints)
        ex = d.constraints[i]
        nzthis = hessian_slice(d, ex, x, H, lambda[i+length(quadconstr)+length(d.m.linconstr)], nzcount, recovery_tmp_storage)
        nzcount += nzthis
    end

    d.eval_hesslag_timer += toq()
    return

end

function hessian_slice(d, ex, x, H, scale, nzcount, recovery_tmp_storage)

    nzthis = length(ex.hess_I)
    if ex.linearity == LINEAR
        @assert nzthis == 0
        return 0
    end
    seed = ex.seed_matrix
    Coloring.prepare_seed_matrix!(seed,ex.rinfo)

    hessmat_eval!(seed, d.reverse_storage_hess, d.forward_storage_hess, ex.nd, ex.adj, ex.const_values, x, d.reverse_output_vector, d.forward_input_vector, ex.rinfo.local_indices)
    # Output is in seed, now recover

    output_slice = sub(H, (nzcount+1):(nzcount+nzthis))
    Coloring.recover_from_matmat!(output_slice, seed, ex.rinfo, recovery_tmp_storage)
    scale!(output_slice, scale)
    return nzthis

end

MathProgBase.isobjlinear(d::JuMPNLPEvaluator) = !d.has_nlobj && (length(d.m.obj.qvars1) == 0)
# interpret quadratic to include purely linear
MathProgBase.isobjquadratic(d::JuMPNLPEvaluator) = !d.has_nlobj

MathProgBase.isconstrlinear(d::JuMPNLPEvaluator, i::Integer) = (i <= length(d.m.linconstr))

function MathProgBase.jac_structure(d::JuMPNLPEvaluator)
    # Jacobian structure
    jac_I = Int[]
    jac_J = Int[]
    A = d.A
    for col = 1:size(A,2)
        for pos = nzrange(A,col)
            push!(jac_I, A.rowval[pos])
            push!(jac_J, col)
        end
    end
    rowoffset = size(A,1)+1
    for c::QuadConstraint in d.m.quadconstr
        aff = c.terms.aff
        for k in 1:length(aff.vars)
            push!(jac_I, rowoffset)
            push!(jac_J, aff.vars[k].col)
        end
        for k in 1:length(c.terms.qvars1)
            push!(jac_I, rowoffset)
            push!(jac_I, rowoffset)
            push!(jac_J, c.terms.qvars1[k].col)
            push!(jac_J, c.terms.qvars2[k].col)
        end
        rowoffset += 1
    end
    for ex in d.constraints
        idx = ex.grad_sparsity
        for i in 1:length(idx)
            push!(jac_I, rowoffset)
            push!(jac_J, idx[i])
        end
        rowoffset += 1
    end
    return jac_I, jac_J
end
function MathProgBase.hesslag_structure(d::JuMPNLPEvaluator)
    d.want_hess || error("Hessian computations were not requested on the call to MathProgBase.initialize.")
    hess_I = Int[]
    hess_J = Int[]

    qobj::QuadExpr = d.m.obj
    for k in 1:length(qobj.qvars1)
        qidx1 = qobj.qvars1[k].col
        qidx2 = qobj.qvars2[k].col
        if qidx2 > qidx1
            qidx1, qidx2 = qidx2, qidx1
        end
        push!(hess_I, qidx1)
        push!(hess_J, qidx2)
    end
    # quadratic constraints
    for c::QuadConstraint in d.m.quadconstr
        for k in 1:length(c.terms.qvars1)
            qidx1 = c.terms.qvars1[k].col
            qidx2 = c.terms.qvars2[k].col
            if qidx2 > qidx1
                qidx1, qidx2 = qidx2, qidx1
            end
            push!(hess_I, qidx1)
            push!(hess_J, qidx2)
        end
    end

    if d.has_nlobj
        append!(hess_I, d.objective.hess_I)
        append!(hess_J, d.objective.hess_J)
    end
    for ex in d.constraints
        append!(hess_I, ex.hess_I)
        append!(hess_J, ex.hess_J)
    end

    return hess_I, hess_J
end
#=
# currently don't merge duplicates (this isn't required by MPB standard)
function affToExpr(aff::AffExpr, constant::Bool)
    ex = Expr(:call,:+)
    for k in 1:length(aff.vars)
        push!(ex.args, Expr(:call,:*,aff.coeffs[k],:(x[$(aff.vars[k].col)])))
    end
    if constant && aff.constant != 0
        push!(ex.args, aff.constant)
    end
    return ex
end

function quadToExpr(q::QuadExpr,constant::Bool)
    ex = Expr(:call,:+)
    for k in 1:length(q.qvars1)
        push!(ex.args, Expr(:call,:*,q.qcoeffs[k],:(x[$(q.qvars1[k].col)]), :(x[$(q.qvars2[k].col)])))
    end
    append!(ex.args, affToExpr(q.aff,constant).args[2:end])
    return ex
end

function MathProgBase.obj_expr(d::JuMPNLPEvaluator)
    if isa(d.m.nlpdata.nlobj, ReverseDiffSparse.SymbolicOutput)
        return ReverseDiffSparse.to_flat_expr(d.m.nlpdata.nlobj)
    else
        return quadToExpr(d.m.obj, true)
    end
end

function MathProgBase.constr_expr(d::JuMPNLPEvaluator,i::Integer)
    nlin = length(d.m.linconstr)
    nquad = length(d.m.quadconstr)
    if i <= nlin
        constr = d.m.linconstr[i]
        ex = affToExpr(constr.terms, false)
        if sense(constr) == :range
            return Expr(:comparison, constr.lb, :(<=), ex, :(<=), constr.ub)
        else
            return Expr(:comparison, ex, sense(constr), rhs(constr))
        end
    elseif i > nlin && i <= nlin + nquad
        i -= nlin
        qconstr = d.m.quadconstr[i]
        return Expr(:comparison, quadToExpr(qconstr.terms, true), qconstr.sense, 0)
    else
        i -= nlin + nquad
        ex = ReverseDiffSparse.to_flat_expr(d.m.nlpdata.nlconstrlist, i)
        constr = d.m.nlpdata.nlconstr[i]
        if sense(constr) == :range
            return Expr(:comparison, constr.lb, :(<=), ex, :(<=), constr.ub)
        else
            return Expr(:comparison, ex, sense(constr), rhs(constr))
        end
    end
end
=#

function _buildInternalModel_nlp(m::Model, traits)

    linobj, linrowlb, linrowub = prepProblemBounds(m)

    nldata::NLPData = m.nlpdata
    if m.internalModelLoaded
        @assert isa(nldata.evaluator, JuMPNLPEvaluator)
        d = nldata.evaluator
    else
        d = JuMPNLPEvaluator(m)
        nldata.evaluator = d
    end

    nlp_lb, nlp_ub = getConstraintBounds(m)
    numConstr = length(nlp_lb)

    m.internalModel = MathProgBase.NonlinearModel(m.solver)

    MathProgBase.loadproblem!(m.internalModel, m.numCols, numConstr, m.colLower, m.colUpper, nlp_lb, nlp_ub, m.objSense, d)
    if traits.int
        if applicable(MathProgBase.setvartype!, m.internalModel, m.colCat)
            MathProgBase.setvartype!(m.internalModel, vartypes_without_fixed(m))
        else
            error("Solver does not support discrete variables")
        end
    end

    if !any(isnan,m.colVal)
        MathProgBase.setwarmstart!(m.internalModel, m.colVal)
    else
        initval = copy(m.colVal)
        initval[isnan(m.colVal)] = 0
        MathProgBase.setwarmstart!(m.internalModel, min(max(m.colLower,initval),m.colUpper))
    end

    m.internalModelLoaded = true

    nothing
end


function solvenlp(m::Model, traits; suppress_warnings=false)

    @assert m.internalModelLoaded

    MathProgBase.optimize!(m.internalModel)
    stat = MathProgBase.status(m.internalModel)

    if stat != :Infeasible && stat != :Unbounded
        m.objVal = MathProgBase.getobjval(m.internalModel)
        m.colVal = MathProgBase.getsolution(m.internalModel)
    end

    if stat != :Optimal
        suppress_warnings || warn("Not solved to optimality, status: $stat")
    end
    if stat == :Optimal && !traits.int
        if applicable(MathProgBase.getconstrduals, m.internalModel) && applicable(MathProgBase.getreducedcosts, m.internalModel)
            nlduals = MathProgBase.getconstrduals(m.internalModel)
            m.linconstrDuals = nlduals[1:length(m.linconstr)]
            # quadratic duals currently not available, formulate as nonlinear constraint if needed
            m.nlpdata.nlconstrDuals = nlduals[length(m.linconstr)+length(m.quadconstr)+1:end]
            m.redCosts = MathProgBase.getreducedcosts(m.internalModel)
        else
            suppress_warnings || Base.warn_once("Nonlinear solver does not provide dual solutions")
        end
    end

    #d = m.nlpdata.evaluator
    #println("feval $(d.eval_f_timer)\nfgrad $(d.eval_grad_f_timer)\ngeval $(d.eval_g_timer)\njaceval $(d.eval_jac_g_timer)\nhess $(d.eval_hesslag_timer)")

    return stat::Symbol

end

#=
# getValue for nonlinear subexpressions
function getValue(x::Union{ReverseDiffSparse.ParametricExpressionWithParams,ReverseDiffSparse.ParametricExpression{0}})
    # messy check to extract model object
    found = false
    m = nothing
    for item in ReverseDiffSparse.expression_data(x)
        if isa(item, JuMPContainer)
            found = true
            m = getmeta(item, :model)
            break
        elseif isa(item, Array{Variable}) && !isempty(item)
            found = true
            m = first(item).m
        elseif isa(item, Variable)
            found = true
            m = item.m
            break
        end
    end
    found || error("Unable to determine which model this expression belongs to. Are there any variables present?")
    return ReverseDiffSparse.getvalue(x, m.colVal)
end
=#
