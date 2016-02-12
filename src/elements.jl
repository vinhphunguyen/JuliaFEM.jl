# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/JuliaFEM.jl/blob/master/LICENSE.md

abstract AbstractElement

type Element{E}
    connectivity :: Vector{Int}
    fields :: Dict{ASCIIString, Field}
    # matrices to construct dual basis
    D :: Matrix{Float64}
    M :: Matrix{Float64}
    A :: Matrix{Float64}
end

function Base.size{E}(::Element{E})
    return size(E)
end

function Base.size{E}(::Element{E}, i::Int64)
    return size(E)[i]
end

function convert{E}(::Type{Element{E}}, connectivity::Vector{Int})
    return Element{E}(connectivity, Dict(), Matrix(), Matrix(), Matrix())
end

function get_integration_points{E}(element::Element{E}, args...)
    return get_integration_points(E, args...)
end

function update_gauss_fields!(element::Element, data::Vector{IntegrationPoint}, time::Real)
    if haskey(element, "integration points")
        # push or update
        if !isapprox(last(element["integration points"]).time, time)
            push!(element["integration points"], time => data)
        else
            last(element["integration points"]).data = data
        end
    else
        # create
        element["integration points"] = Field(time => data)
    end
end

""" Get FieldSet from element. """
function Base.getindex(element::Element, field_name)
    return element.fields[field_name]
end

function Base.length{E}(element::Element{E})
    size(E)[2]
end

"""Add new Field to element.

Examples
--------
>>> element["temperature"] = [1, 2, 3, 4]
>>> element["temperature"] = (0.0, [0, 0, 0, 0]), (1.0, [1, 2, 3, 4])
>>> element["temperature"] = (0.0 => [0, 0, 0, 0], 1.0 => [1, 2, 3, 4])
"""
function Base.setindex!(element::Element, data, name::ASCIIString)
    element.fields[name] = Field(data)
end
function Base.setindex!(element::Element, field::Field, name::ASCIIString)
    element.fields[name] = field
end
function Base.setindex!(element::Element, data::Tuple, name::ASCIIString)
    element.fields[name] = Field(data...)
end

function get_connectivity(el::Element)
    return el.connectivity
end

typealias VecOrIP Union{Vector, IntegrationPoint}

function call(element::Element, field_name::ASCIIString, time::Real, variation=nothing)
    return isa(variation, Void) ? element[field_name](time) : variation
end

function call(element::Element, field_name::ASCIIString, xi::VecOrIP, time::Number, variation=nothing)
    field = element(field_name, time, variation)
#   field = isa(variation, Void) ? element[field_name](time) : variation
    basis = get_basis(element)
    return basis(field, xi)
end

function call(element::Element, field_name::ASCIIString, xi::VecOrIP, time::Number, ::Type{Val{:grad}}, variation=nothing)
#   field = isa(variation, Void) ? element[field_name](time) : variation
    field = element(field_name, time, variation)
    basis = get_basis(element)
    geom = element["geometry"](time)
    return basis(geom, field, xi, Val{:grad})
end

function call(element::Element, field_name::ASCIIString, xi::VecOrIP)
    field = element[field_name]
    basis = get_basis(element)
    return basis(element[field_name], xi)
end

function call(element::Element, field_name::ASCIIString, xi::VecOrIP, ::Type{Val{:grad}})
    field = element[field_name]
    geom = element["geometry"]
    basis = get_basis(element)
    return basis(geom, field, xi, Val{:grad})
end

function call(element::Element, field_name::ASCIIString, time::Number)
    return element[field_name](time)
end

function get_dbasis{E<:AbstractElement}(::Type{E}, xi::Vector)
    basis(xi) = vec(get_basis(E, xi))
    return ForwardDiff.jacobian(basis, xi, cache=autodiffcache)'
end

function get_basis{E}(element::Element{E}, ip::IntegrationPoint)
    return get_basis(E, ip.xi)
end

function get_basis{E}(::Type{Element{E}}, xi::Vector{Float64})
    return get_basis(E, xi)
end

function get_basis{E}(element::Element{E}, xi::Vector{Float64})
    return get_basis(E, xi)
end

function call{E}(element::Element{E}, xi::VecOrIP, time::Float64=0.0)
    return get_basis(element, xi)
end

""" Return dual basis transformation matrix Ae. """
function get_dualbasis(element::Element, time::Real)
    if length(element.A) == 0
        nnodes = size(element, 2)
        De = zeros(nnodes, nnodes)
        Me = zeros(nnodes, nnodes)
        for ip in get_integration_points(element, Val{3})
            w = ip.weight
            J = get_jacobian(element, ip, time)
            JT = transpose(J)
            if size(JT, 2) == 1  # plane problem
                # || ∂X/∂ξ ||
                w *= norm(JT)
            else
                # || ∂X/∂ξ₁ × ∂X/∂ξ₂ ||
                w *= norm(cross(JT[:,1], JT[:,2]))
            end
            N = element(ip, time)
            De += w*diagm(vec(N))
            Me += w*N'*N
        end
        element.D = De
        element.M = Me
        element.A = De*inv(Me)
    end
    return element.D, element.M, element.A
end

function call(element::Element, xi::VecOrIP, time::Real, ::Type{Val{:dualbasis}})
    De, Me, Ae = get_dualbasis(element, time)
    N = get_basis(element, xi)
    Phi = Ae*N'
    return Phi'
end

function get_basis{E}(element::Element{E})
    basis = CVTI(
        (xi::Vector) -> get_basis(E, xi),
        (xi::Vector) -> get_dbasis(E, xi))
    return basis
end

function call{E}(element::Element{E}, xi::VecOrIP, ::Type{Val{:grad}})
    basis = get_basis(element)
    geom = element["geometry"]
    return basis(geom, xi, Val{:grad})
end

function call{E}(element::Element{E}, xi::VecOrIP, time::Float64, ::Type{Val{:grad}})
    basis = get_basis(element)
    return basis(element["geometry"](time), xi, Val{:grad})
end

function call(element::Element, field_name::ASCIIString)
    return element[field_name]
end


""" Return the jacobian of element. """
function get_jacobian{E}(element::Element{E}, xi::Vector{Float64}, time::Real)
    X = element("geometry", time)
    dN = get_dbasis(E, xi)
    J = sum([kron(dN[:,i], X[i]') for i=1:length(X)])
    return J
end
function get_jacobian{E}(element::Element{E}, ip::IntegrationPoint, time::Real)
    return get_jacobian(element, ip.xi, time)
end

""" Return Jacobian of element in deformed state. """
function get_jacobian{E}(element::Element{E}, xi::Vector{Float64}, time::Real, ::Type{Val{:deformed}})
    x = element("geometry", time)
    if haskey(element, "displacement")
        x += element("displacement", time)
    end
    dN = get_dbasis(E, xi)
    j = sum([kron(dN[:,i], x[i]') for i=1:length(x)])
    return j
end
function get_jacobian{E}(element::Element{E}, ip::IntegrationPoint, time::Real, ::Type{Val{:deformed}})
    return get_jacobian(element, ip.xi, time, Val{:deformed})
end


""" Check does field exist. """
function Base.haskey(element::Element, what)
    haskey(element.fields, what)
end

""" Calculate local normal-tangential coordinates for element. """
function calculate_normal_tangential_coordinates!{E}(element::Element{E}, time::Real)
    ntcoords = Matrix[]
    normals = Vector{Float64}[]
    refcoords = get_reference_element_coordinates(E)
    x = element("geometry", time)
    for xi in refcoords
        dN = get_dbasis(E, xi)*x
        n, m = size(dN)
        @assert n != m # if n == m -> this is not manifold
        if m == 1 # plane case
            tangent = dN / norm(dN)
            normal = [-tangent[2] tangent[1]]'
            push!(normals, vec(normal))
            push!(ntcoords, [normal tangent])
        elseif m == 2
            normal = cross(dN[:,1], dN[:,2])
            normal /= norm(normal)
            u1 = normal
            j = indmax(abs(u1))
            v2 = zeros(3)
            v2[mod(j,3)+1] = 1.0
            u2 = v2 - dot(u1, v2) / dot(v2, v2) * v2
            u3 = cross(u1, u2)
            tangent1 = u2/norm(u2)
            tangent2 = u3/norm(u3)
            push!(ntcoords, [normal tangent1 tangent2])
            push!(normals, vec(normal))
        else
            error("calculate_normal_tangential_coordinates!(): n=$n, m=$m")
        end
    end
    element["normal-tangential coordinates"] = ntcoords
    element["normals"] = normals
end

""" Return list of nodes / connectivity points from a set of elements.
"""
function get_nodes(elements::Vector)
    nodes = Set{Int64}()
    for element in elements
        push!(nodes, get_connectivity(element)...)
    end
    nodes = sort(collect(nodes))
    return nodes
end

""" Calculate normal-tangential coordinates for a set of elements. 

Notes
-----
Average normals so that normals are unique in nodes.
"""

function calculate_normal_tangential_coordinates!(elements::Vector, time::Real, configuration::Symbol=:deformed)
    if size(elements[1], 1) == 1
        return calculate_normal_tangential_coordinates!(elements, time, Val{2}, configuration)
    else
        return calculate_normal_tangential_coordinates!(elements, time, Val{3}, configuration)
    end
end

""" Calculate normal-tangential coordinates for 2d case.

Notes
-----
n = (e₃×∂X/∂ξ) / || e₃×∂X/∂ξ || and e₃ = [0 0 1]
"""
function calculate_normal_tangential_coordinates!(elements::Vector, time::Real, ::Type{Val{2}}, configuration::Symbol)
    nodes = get_nodes(elements)
    n = zeros(2, maximum(nodes))
    Q = [0 -1; 1 0]
    for element in elements
        gdofs = get_gdofs(element, 1)
        for ip in get_integration_points(element, Val{3})
            if configuration == :deformed
                J = get_jacobian(element, ip, time, Val{:deformed})
            else
                J = get_jacobian(element, ip, time)
            end
            N = element(ip, time)
            n[:, gdofs] += ip.weight*Q*J'*N
        end
    end
    t = zeros(n)
    for i=1:size(n,2)
        n[:,i] = n[:,i] / norm(n[:,i])
        t[:,i] = [-n[2,i], n[1,i]]
    end
    for element in elements
        node_ids = get_connectivity(element)
        Q = Matrix{Float64}[ [n[:,i] t[:,i]] for i in node_ids]
        element["normal-tangential coordinates"] = (time => Q)
        element["normals"] = Vector{Float64}[n[:,i] for i in node_ids]
    end
end

""" Calculate normal-tangential coordinates for 3d case.
"""
function calculate_normal_tangential_coordinates!(elements::Vector, time::Real, ::Type{Val{3}})
    nodes = get_nodes(elements)
    n = zeros(3, maximum(nodes))
    for element in elements
        gdofs = get_gdofs(element, 1)
        for ip in get_integration_points(element, Val{3})
            J = transpose(get_jacobian(element, ip, time, Val{:deformed}))
            N = element(ip, time)
            c = reshape(cross(J[:,1], J[:,2]), 3, 1)
            n[:, gdofs] += ip.weight*c*N
        end
    end
    t1 = zeros(n)
    t2 = zeros(n)
    for i=1:size(n,2)
        i in nodes || continue
        n[:,i] = n[:,i] / norm(n[:,i])
        u1 = n[:,i]
        j = indmax(abs(n[:,i]))
        v2 = zeros(3)
        v2[mod(j,3)+1] = 1.0
        u2 = v2 - dot(u1, v2) / dot(v2, v2) * v2
        u3 = cross(u1, u2)
        t1[:,i] = u2/norm(u2)
        t2[:,i] = u3/norm(u3)
    end
    for element in elements
        node_ids = get_connectivity(element)
        Q = Matrix{Float64}[ [n[:,i] t1[:,i] t2[:,i]] for i in node_ids]
        element["normal-tangential coordinates"] = (time => Q)
        element["normals"] = Vector{Float64}[n[:,i] for i in node_ids]
    end
end

""" Update element field based on a dictionary of nodal data and connectivity information.

Examples
--------
julia> data = Dict(1 => [0.0, 0.0], 2 => [1.0, 2.0])
julia> element = Seg2([1, 2])
julia> update!(element, "geometry", data)

As a result element now have time invariant (variable) vector field "geometry" with data ([0.0, 0.0], [1.0, 2.0]).

"""
function update!(element::Element, field_name::ASCIIString, data::Dict)
    element[field_name] = [data[i] for i in get_connectivity(element)]
end

function update!(element::Element, field_name::ASCIIString, data::Union{Real, Vector, Pair}...)
    element[field_name] = data
end

""" Update values for several elements at once. """
# FIXME: with or without {T} ?
function update!{T}(elements::Vector{Element{T}}, field_name::ASCIIString, data...)
    for element in elements
        update!(element, field_name, data...)
    end
end
function update!(elements::Vector{Element}, field_name::ASCIIString, data...)
    for element in elements
        update!(element, field_name, data...)
    end
end
