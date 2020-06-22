%% SNW_VFI_MAIN Solves Policy/Value Function SNW (Loop)
%    Given parameters, iterate over life cycle, given age, marital status,
%    education level and child count, as well as persistent productivity
%    shock process, solve for optimal dynamic savings choices given
%    expectation of kid count transition and productivity shock transition.
%
%    Pref, Technology, and prices SCALARS:
%
%    * BETA discount
%    * THETA total factor productivity normalizer
%    * R interest rate
%
%    Vectorized State Space ARRAYS:
%
%    * AGRID asset grid
%    * ETA_GRID productivity shock grid
%
%    Transition Matrixes ARRAYS:
%
%    * PI_ETA shock productivity transition
%    * PI_KIDS shock kids count transition
%    * PSI shock survival probability
%
%    Permanent Education Type Heterogeneity ARRAYS:
%
%    * EPSILON perfect-foresight education type transition
%    * SS Social Security
%
%    [V_VFI,AP_VFI,CONS_VFI,EXITFLAG_VFI] = SNW_VFI_MAIN(MP_PARAMS) invoke
%    model with externally set parameter map MP_PARAMS.
%
%    [V_VFI,AP_VFI,CONS_VFI,EXITFLAG_VFI] = SNW_VFI_MAIN(MP_PARAMS,
%    MP_CONTROLS) invoke model with externally set parameter map MP_PARAMS
%    as well as control mpa MP_CONTROLS.
%
%    See also SNWX_VFI_MAIN
%

%%
function [V_VFI,ap_VFI,cons_VFI,exitflag_VFI]=snw_vfi_main(varargin)

%% Catch Param Error
if (~isempty(varargin))
    
    if (length(varargin)==1)
        [mp_params] = varargin{:};
        mp_controls = snw_mp_controls('default_base');
    elseif (length(varargin)==2)
        [mp_params, mp_controls] = varargin{:};
    end
    
else
    
    mp_params = snw_mp_param('default_tiny');
    mp_controls = snw_mp_controls('default_base');
    
end

%% Reset All globals
% globals = who('global');
% clear(globals{:});
% Parameters used in this code directly
global beta theta r agrid epsilon eta_grid SS pi_eta pi_kids psi n_jgrid n_agrid n_etagrid n_educgrid n_marriedgrid n_kidsgrid
% Used in functions that are called by this code
global gamma g_n g_cons a2 cons_allocation_rule

%% Parse Model Parameters
params_group = values(mp_params, {'gamma', 'beta', 'theta', 'cons_allocation_rule', ...
    'r', 'g_n', 'g_cons', 'a2'});
[gamma, beta, theta, cons_allocation_rule, ...
    r, g_n, g_cons, a2] = params_group{:};

params_group = values(mp_params, {'agrid', 'eta_grid'});
[agrid, eta_grid] = params_group{:};

params_group = values(mp_params, {'pi_eta', 'pi_kids', 'psi'});
[pi_eta, pi_kids, psi] = params_group{:};

params_group = values(mp_params, {'epsilon', 'SS'});
[epsilon, SS] = params_group{:};

params_group = values(mp_params, ...
    {'n_jgrid', 'n_agrid', 'n_etagrid', 'n_educgrid', 'n_marriedgrid', 'n_kidsgrid'});
[n_jgrid, n_agrid, n_etagrid, n_educgrid, n_marriedgrid, n_kidsgrid] = params_group{:};

%% Parse Model Controls
% Minimizer Controls
params_group = values(mp_controls, ...
    {'A_aux', 'B_aux', ...
     'Aeq', 'Beq',...
     'nonlcon', 'options', 'options2'});
[A_aux, B_aux, ...
    Aeq, Beq, ...
    nonlcon, options, options2] = params_group{:};

% Profiling Controls
params_group = values(mp_controls, {'bl_timer'});
[bl_timer] = params_group{:};

% Display Controls
params_group = values(mp_controls, {'bl_print_iter'});
[bl_print_iter] = params_group{:};

%% Timing and Profiling Start
if (bl_timer)
    tic
end

%% Solve optimization problem

V_VFI=NaN(n_jgrid,n_agrid,n_etagrid,n_educgrid,n_marriedgrid,n_kidsgrid);
ap_VFI=NaN(n_jgrid,n_agrid,n_etagrid,n_educgrid,n_marriedgrid,n_kidsgrid);
cons_VFI=NaN(n_jgrid,n_agrid,n_etagrid,n_educgrid,n_marriedgrid,n_kidsgrid);

exitflag_VFI=NaN(n_jgrid,n_agrid,n_etagrid,n_educgrid,n_marriedgrid,n_kidsgrid);

% Solve for value function and policy functions by means of backwards induction
for j=n_jgrid:(-1):1 % Age
    for a=1:n_agrid % Assets
        for eta=1:n_etagrid % Productivity
            for educ=1:n_educgrid % Educational level
                for married=1:n_marriedgrid % Marital status
                    for kids=1:n_kidsgrid % Number of kids
                        
                        if j==n_jgrid
                            
                            ap_VFI(j,a,eta,educ,married,kids)=0;
                            cons_VFI(j,a,eta,educ,married,kids) = consumption(j,a,eta,educ,married,kids,ap_VFI(j,a,eta,educ,married,kids));
                            
                            if cons_VFI(j,a,eta,educ,married,kids)<=0
                                disp([j,a,eta,educ,married,kids,cons_VFI(j,a,eta,educ,married,kids)])
                                error('Non-positive consumption')
                            end
                            
                            V_VFI(j,a,eta,educ,married,kids)=utility(cons_VFI(j,a,eta,educ,married,kids),married,kids);
                            
                        else
                            
                            % Solve for next period's assets
                            x0=agrid(a); % Initial guess for ap
                            
                            amin=0;
                            [inc,earn]=individual_income(j,a,eta,educ);
                            spouse_inc=spousal_income(j,educ,kids,earn,SS(j,educ));
                            
                            amax = min(agrid(end), ...
                                (1+r)*agrid(a) ...
                                + epsilon(j,educ)*theta*exp(eta_grid(eta)) ...
                                + SS(j,educ) ...
                                + (married-1)*spouse_inc ...
                                - max(0,Tax(inc,(married-1)*spouse_inc)));
                            
                            [ap_aux,~,exitflag_VFI(j,a,eta,educ,married,kids)]=...
                                fmincon(@(x)value_func_aux(x,j,a,eta,educ,married,kids,V_VFI), ...
                                x0,A_aux,B_aux,Aeq,Beq,amin,amax,nonlcon,options);
                            
                            ind_aux=find(agrid<=ap_aux,1,'last');
                            
                            % Linear interpolation
                            if ap_aux==0
                                inds(1)=1;
                                inds(2)=1;
                                vals(1)=1;
                                vals(2)=0;
                                
                            elseif ap_aux==agrid(n_agrid)
                                inds(1)=n_agrid;
                                inds(2)=n_agrid;
                                vals(1)=1;
                                vals(2)=0;
                                
                            else
                                inds(1)=ind_aux;
                                inds(2)=ind_aux+1;
                                vals(1)=1-((ap_aux-agrid(inds(1)))/(agrid(inds(2))-agrid(inds(1))));
                                vals(2)=1-vals(1);
                                
                            end
                            
                            cont=0;
                            for etap=1:n_etagrid
                                for kidsp=1:n_kidsgrid
                                    cont=cont ...
                                        +pi_eta(eta,etap)*pi_kids(kids,kidsp,j,married)*(...
                                            vals(1)*V_VFI(j+1,inds(1),etap,educ,married,kidsp) ...
                                            +vals(2)*V_VFI(j+1,inds(2),etap,educ,married,kidsp));
                                end
                            end
                            
                            c_aux=consumption(j,a,eta,educ,married,kids,ap_aux);
                            
                            ap_VFI(j,a,eta,educ,married,kids)=ap_aux;
                            cons_VFI(j,a,eta,educ,married,kids)=c_aux;
                            
                            V_VFI(j,a,eta,educ,married,kids)=utility(c_aux,married,kids)+beta*psi(j)*cont;
                            
                            c_aux3=consumption(j,a,eta,educ,married,kids,0);
                            
                            cont=0;
                            for etap=1:n_etagrid
                                for kidsp=1:n_kidsgrid
                                    cont=cont+pi_eta(eta,etap)*pi_kids(kids,kidsp,j,married)*V_VFI(j+1,1,etap,educ,married,kidsp);
                                end
                            end
                            V_aux3=utility(c_aux3,married,kids)+beta*psi(j)*cont;
                            
                            if V_aux3>V_VFI(j,a,eta,educ,married,kids)
                                ap_VFI(j,a,eta,educ,married,kids)=0;
                                cons_VFI(j,a,eta,educ,married,kids)=c_aux3;
                                
                                V_VFI(j,a,eta,educ,married,kids)=V_aux3;
                            end
                            
                            if cons_VFI(j,a,eta,educ,married,kids)<=0
                                disp([j,a,eta,educ,married,kids,cons_VFI(j,a,eta,educ,married,kids)])
                                error('Non-positive consumption')
                            end
                            
                        end
                        
                    end
                end
            end
        end
    end
    
    if (bl_print_iter)
        disp(strcat(['Finished Age Group:' num2str(j) ' of ' num2str(n_jgrid)]));
    end
    
end

%% Timing and Profiling End
if (bl_timer)
    toc;
end

end
