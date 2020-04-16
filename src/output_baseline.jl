using CSV, DataFrames
using DataFramesMeta
using Dates

include("$(@__DIR__)" * "/mip.jl")
include("$(@__DIR__)" * "/output_helpers.jl")

"""
    Main solver function
    Args:
        - model_choice: ode or ihme epidemic model
        - surge_days: list of dates when surge supply happens
        - surge_amount: list of surge amount at each surge day
        - lasso: the LASSO penalty coefficient on transfers (exact sparse will not scale)

    Retun:
        - supply: 
        - transfer:
"""
# ------ Functions -------
# get list of states based on model choice: this should be redundaant now but acts as a safeguard
function load_states(model_choice="ode")
    states_all = CSV.read("$(@__DIR__)/../processed/state_list.csv")[:State]
    if model_choice == "ode"
        df = CSV.read("$(@__DIR__)/../processed/predicted_ode/AllStates.csv")
    elseif model_choice == "ihme"
        df = CSV.read("$(@__DIR__)/../processed/predicted_ihme/AllStates.csv");
    end

    states = intersect(unique(df[:State]), states_all)
    return states
end

# read projection based on model choice
function load_projections(state; model="ode")
     if model == "ode"
        df = CSV.read("$(@__DIR__)/../processed/predicted_ode/AllStates.csv")
    elseif model == "ihme"
        df = CSV.read("$(@__DIR__)/../processed/predicted_ihme/AllStates.csv")
    end
    if state == "all"
        return df
    else
        df_sub = @where(df, :State .== state)
        df_sub = df_sub[:,2:end] # remove state name
    end
end

# 1. construct demand_matrix
function demand_matrix(model_choice)
    states = load_states(model_choice)
    state = states[1]
    df = load_projections(state, model = model_choice)
    df[:, Symbol("Vent_$state")] = df[:, :Ventilators]
    df = df[:, [:Day, Symbol("Vent_$state")]]
    for state in states[2:end]
        tmpdf = load_projections(state, model = model_choice)
        tmpdf[:, Symbol("Vent_$state")] = tmpdf[:, :Ventilators]
        tmpdf = tmpdf[:, [:Day, Symbol("Vent_$state")]]
        df = join(df, tmpdf, kind=:inner, on = :Day)
    end
    demand_days = df[:,1]
    demands = df[:,2:end] |> Matrix
    demands = Matrix(demands');
    return demands, demand_days
    end

# 2. load supply
function load_supply(states)
    df_supply = CSV.read("$(@__DIR__)/../processed/ventilator_table_calculated.csv")
    base_supply = zeros(length(states))
    for (i, state) in enumerate(states)
        base_supply[i] = df_supply[df_supply[:, :STNAME].==state,:VentCalc_2019][1]
    end
    return base_supply
end

# 3. load surge_supply
function load_surge_supply(demands, dates=[1], surge_amount=[0])
    surge_supply = zeros(size(demands, 2));
    d0=1
    for i in 1:size(dates,1)
        d1= dates[i]
        surge_supply[d0:d1] .= surge_amount[i]/(d1-d0+1);
        d0+=dates[i];
        end
    return surge_supply;
end
# ------ End of Functions -------

function solve_baselines()
    supply_table = DataFrame()

    for model_choice in ["ode", "ihme"]
        states = load_states(model_choice)

        #1. load demand
        demands, demand_days = demand_matrix(model_choice)
        #2. load base_supply
        base_supply = load_supply(states).*0.5

        # expand to supply each day
        supply = repeat(base_supply, outer = [1,length(demand_days)])

        ## Supply table
        supply_long = supplies_to_long(supply, demands, states, demand_days, base_supply)
        supply_long[:DataSource] = model_choice
        supply_long[:Fmax] = 1000
        supply_long[:Buffer] = 1000
        supply_long[:SurgeCorrection] = 1000
        supply_table = vcat(supply_table, supply_long)
    end

    return supply_table
end

version = ARGS[1]
supply = solve_baselines()
CSV.write("$(@__DIR__)/../results/supply_baseline_$version.csv", supply)
