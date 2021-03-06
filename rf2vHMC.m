% HMC sampler with reduced flip using two momentum variables.
%Mayur Mudigonda

% X is the current sample
% state holds the complete state of the sampler, and can be passed back in to resume
%   at the same location
% varargin contains arguments that are passed through to E( X, varargin ) and dEdX( X, varargin )
% opts contains options for the sampler

function [X, state] = rf2vHMC( opts, state, varargin )
    
    % load parameters
    f_E = getField( opts, 'E', 0 );
    f_dEdX = getField( opts, 'dEdX', 0 );
        
    %max_leaps = getField( opts, 'MaxLeaps', 10);
    max_leaps = getField( opts, 'MaxLeaps', 4);

    epsilon = getField( opts, 'epsilon', 0.1 );
    LeapSize = getField(opts, 'LeapSize',1);
    opts.LeapSize = LeapSize; % opts gets passed around
    opts.epsilon = epsilon;
    alpha = getField( opts, 'alpha', 0.2);
    beta = alpha^(1 / (epsilon*LeapSize));
    beta = getField( opts, 'beta', beta);
    %assert(nobeta == -1); % make sure nowhere is using the old scheme
%    fprintf('Value of Beta is %f',beta);
    
    % this controls whether or not to use the reduced flip mode
    % default (0) is reduced flip mode
    flip_on_rej = getField( opts, 'FlipOnReject', 0); % remember, 0 is standard
    %1 is reduced flipping and 2 is 2 momentum variable

    
    T = getField( opts, 'T', 1 ); %%%T is not being defined in make_figures
    szb = getField( opts, 'BatchSize', 1 );
    %szb = 1; % for now, this is always 1...
    szd = getField( opts, 'DataSize', 10 );
    debug = getField( opts, 'Debug', 0 );

    % initialize the state variable if not already initialized
    if isempty(state)        
        % the random seed reset will make experiments exactly repeatable
        %reset(RandStream.getDefaultStream);
        %Scaling the initializations to be from interest distr
        %Not doing this for circle
        % DEBUG
        state.X = randn( szd, szb );
        state.X = getField( opts, 'Xinit', state.X );

        state.V1 = randn( szd, szb );
        if flip_on_rej == 2
             state.V2 = randn(szd,szb);
        end
        %state.X(:) = 0;% use this for not initalizing the samples from the interest distrib
        %state.X(1,:) = 1;% ditto above
        % state.steps provides counters for each kind of transition
        state.steps = [];
        state.steps.leap = zeros(max_leaps,1);
        state.steps.flip = 0;
        state.steps.stay = 0;
        state.steps.total = 0;
        state.funcevals = 0;
%         state.steps.rej = 0;
        if flip_on_rej == 2
            state.steps.swap = 0;
            state.steps.flip_swap = 0;
            state.optim.fval(state.steps.total+1)=0;
            state.optim.exit(state.steps.total+1)=0;
            state.optim.pval(state.steps.total+1,1:5)=zeros(1,5);
        end                
        % populate the energy and gradient at the initial position       
        state.dEdX = f_dEdX( state.X, varargin{:} );
        state.E = f_E( state.X, varargin{:} );
    end

    global funcevals_inc;
    funcevals_inc = 0;
    
    for t = 1:T % iterate over update steps
        if debug
            fprintf( '.' );
        end
        
        if flip_on_rej==2
            state.optim.pval(state.steps.total+1,:) = zeros(1,5);
            state.optim.fval(state.steps.total+1) = 0;
            state.optim.exit(state.steps.total+1) = 0;
        end
     
        % state.X(:,1)'

        %assert(max(state.E)<5); %DEBUG
        L_state = leap_HMC(state,[],opts,varargin{:});
        %assert(max(L_state.E)<5); %DEBUG

        % % DEBUG
        % L_state.X(:,1)'

        r_L = leap_prob(state,L_state,flip_on_rej); % this should be the same as p_lea        
        % compare against a random number to decide whether to accept
        rnd_cmp = rand(1,szb);
        gd = (rnd_cmp < r_L);
        % update the current state for the samples where the forward transition
        % was accepted
        % TODO this will only work for batch size 1
        if sum(gd) > 0
            state = update_state(state,L_state,gd,flip_on_rej);
            state.steps.leap(1) = state.steps.leap(1) + sum(gd);
        end
        % bd indexes the samples for which the forward transition was rejected
        bd = rnd_cmp > r_L;
        %If there are samples that are rejected
        if sum(bd) > 0
            switch flip_on_rej
                %run the reverse dynamics.
                
                %Standard HMC flipping = 1 - leap
                case 0
                    state = flip_HMC(state,bd);
                    %state.V1(:,bd) = -state.V1(:,bd);   
                    state.steps.flip = state.steps.flip + sum(bd);
                %Jascha - reduced flipping
                case 1
                    %run the leaps
                    F_state = flip_HMC(state,bd);
                    LF_state = leap_HMC(F_state,bd,opts,varargin{:});
                    r_LF = leap_prob(F_state,LF_state,flip_on_rej);
                    r_F = r_LF - r_L;
                    r_F(r_F < 0) = 0;
                    flip_ind = (rnd_cmp < r_L + r_F) & bd;
                    state = flip_HMC(state,flip_ind);
                    %state.V1(:,flip_ind) = -state.V1(:,flip_ind);
                    state.steps.flip = state.steps.flip + sum(flip_ind);
                    state.steps.stay = state.steps.stay + sum(~flip_ind) - sum(gd);
                case 3
                    % n steps
                    state_ladder = {};
                    bd_lad = bd;
                    %bd_lad
                    state_ladder{1} = state; % Present State
                    state_ladder{2} = L_state; % Leap State
                    %state_ladder{1}.E %DEBUG
                    %state_ladder{2}.E %DEBUG
                    for nn = 3:max_leaps+1 % Evaluating How far we can leap
                        state_ladder{nn} = leap_HMC(state_ladder{nn-1}, bd_lad, opts, varargin{:});
                        %assert(max(abs(hamiltonian_HMC(state_ladder{nn-1}, [], 3) - hamiltonian_HMC(state_ladder{nn}, [], 3)))<3);
                        %state_ladder{nn}.E %DEBUG
                        [~,~,p_cum] = leap_prob_recurse(state_ladder{1:nn});
                        %assert(max(p_cum.*state_ladder{nn}.E)<5); %DEBUG
                        %p_cum
                        jump_ind = (rnd_cmp < p_cum) & bd_lad;
                        state = update_state(state,state_ladder{nn},jump_ind,flip_on_rej);
                        bd_lad = bd_lad & ~jump_ind;
                        state.steps.leap(nn-1) = state.steps.leap(nn-1) + sum(jump_ind);
                        if sum(bd_lad) == 0
                            break
                        end
                    end
                    % and if there are any left, flip them
                    if sum(bd_lad) > 0
                        state = flip_HMC(state,bd_lad);
                        state.steps.flip = state.steps.flip + sum(bd_lad);
                    end
                    %state.E
                %Jascha + Mayur - 2 momentum variable 
                case 2
                    %we now have to calculate the 16 different probabilities
                    %r_I, r_F, r_S, r_FS of state \zeta
                    %r_I, r_F, r_S, r_FS of state \F\zeta
                    %r_I, r_F, r_S, r_FS of state \S\zeta
                    %r_I, r_F, r_S, r_FS of state \F\S \zeta           
                    %But, remember only 4 of these (that belong to zeta)are actually what we care about!
                    %because we set the Leap probabilities
                    %Let's set the leap probabilities first
                    %To do this, we need to calculate prob of leap(ed) states, but while we
                    %are at that we can also calculate the prob of the other states
                    %that we need for the linprog (from notes/equations)
                    %Basic states
                    %L_state = leap_HMC(state,bd,opts,varargin{:});
                    S_state = swap_HMC(state,bd);
                    F_state = flip_HMC(state,bd);
                    FS_state = flip_HMC(S_state,bd);

                    %two operations
                    LS_state = leap_HMC(S_state,bd,opts,varargin{:});
                    LF_state = leap_HMC(F_state,bd,opts,varargin{:});
                    FL_state = flip_HMC(L_state,bd);

                    %three operations
                    LFS_state = leap_HMC(FS_state,bd,opts,varargin{:});
                    FLF_state = flip_HMC(LF_state,bd);
                    FLS_state = flip_HMC(LS_state,bd);

                    %four operations
                    FLFS_state = flip_HMC(LFS_state,bd);

                    %Inverse states %%This is why we are not using L_inv
                    %state!
                    Linv_state = FLF_state; %leap_inv_HMC(state,bd,opts,varargin{:});
                    LinvF_state = FL_state; %leap_inv_HMC(F_state,bd,opts,varargin{:});
                    LinvFS_state = FLS_state; %leap_inv_HMC(FS_state,bd,opts,varargin{:});
                    LinvS_state = FLFS_state; %leap_inv_HMC(S_state,bd,opts,varargin{:});

                    %compute the leap probabilities we need!
%                     r_L = leap_prob(state,L_state,flip_on_rej); 
                    r_L_Linv = leap_prob(Linv_state,state,flip_on_rej);

                    r_L_S = leap_prob(S_state,LS_state,flip_on_rej);
                    r_L_LinvS = leap_prob(LinvS_state,S_state,flip_on_rej);

                    r_L_FS = leap_prob(FS_state,LFS_state,flip_on_rej);
                    r_L_LinvFS = leap_prob(LinvFS_state,FS_state,flip_on_rej);

                    r_L_F = leap_prob(F_state,LF_state,flip_on_rej);
                    r_L_LinvF = leap_prob(LinvF_state,F_state,flip_on_rej);
                    %Lin prog constraints            
                    %lb and ub
                    lb = zeros(1,16); 
                    ub = ones(1,16);

                    %aeq and beq
                    %Zeta        S_Zeta      F_Zeta      FS_Zeta
                    %I  F  S  FS I  F  S FS  I  F  S FS  I  F  S  FS
                    aeq=...
                    [1  1  1  1  0  0  0  0  0  0  0  0  0  0  0  0; %make pdf
                     0  0  0  0  1  1  1  1  0  0  0  0  0  0  0  0; %make pdf
                     0  0  0  0  0  0  0  0  1  1  1  1  0  0  0  0; %make pdf
                     0  0  0  0  0  0  0  0  0  0  0  0  1  1  1  1; %make pdf
                     0  1  1  1  0  0 -1  0  0 -1  0  0  0  0  0 -1; %equlibiria Zeta
                     0  0 -1  0  0  1  1  1  0  0  0 -1  0 -1  0  0; %equilibria S Zeta
                     0 -1  0  0  0  0  0 -1  0  1  1  1  0  0 -1  0; %equilibria F Zeta             
                     0  0  0 -1  0 -1  0  0  0  0 -1  0  0  1  1  1  %equlibria for FS Zeta
                     ];

                    beq=...
                    [1-r_L;
                     1-r_L_S;
                     1-r_L_F;
                     1-r_L_FS;
                     ((exp(hamiltonian_HMC(FLF_state,[],flip_on_rej)).*r_L_Linv)...
                     ./exp(hamiltonian_HMC(state,[],flip_on_rej))) - r_L;
                     ((exp(hamiltonian_HMC(FLFS_state,[],flip_on_rej)).*r_L_LinvS)...
                     ./exp(hamiltonian_HMC(S_state,[],flip_on_rej))) - r_L_S;
                     ((exp(hamiltonian_HMC(FL_state,[],flip_on_rej)).*r_L_LinvF)...
                     ./exp(hamiltonian_HMC(F_state,[],flip_on_rej))) - r_L_F;
                     ((exp(hamiltonian_HMC(FLS_state,[],flip_on_rej)).*r_L_LinvFS)...
                     ./exp(hamiltonian_HMC(FS_state,[],flip_on_rej))) - r_L_FS;             
                     ];

%                    f = [0 1 -1 0 0 1 -1 0 0 1 -1 0 0 1 -1 0];
                     f = [0 1 -1e-4 0 0 1 -1e-4 0 0 1 -1e-4 0 0 1 -1e-4 0];
                     f = f + rand(1,16)/1e6;
                    try
                        for i=1:size(beq,2)
                            [x_tmp,fval,exitflag,output] = linprog(f,[],[],aeq,...
                                beq(:,i),lb,ub, [], optimset('Display', 'off')); 
                            if i==1
                                x = x_tmp;
                            else
                                x = horzcat(x,x_tmp);
                            end
                        end

                    catch err
                        err.message
                        keyboard
                        if (sum(x(1:4))+r_L~=1)
                            disp('did not sum to 1')
                        end
                    end
                    stay = (r_L < rnd_cmp & rnd_cmp < r_L+x(1) & bd);
                    if sum(stay)>0
                        state.steps.stay = state.steps.stay + sum(stay);
    %                     break;
                    end                
                    flip = (r_L+x(1) < rnd_cmp & rnd_cmp < r_L+x(1)+x(2) & bd);
                    if sum(flip)>0
                        state.steps.flip = state.steps.flip +sum(flip);
                        state = flip_HMC(state,bd);
    %                     break;
                    end
                    swap = (r_L+x(1)+x(2) < rnd_cmp & rnd_cmp < r_L+x(1)+x(2)+x(3) & bd);
                    if sum(swap)>0
                        state.steps.swap = state.steps.swap + sum(swap);
                        state = swap_HMC(state,bd);
    %                     break;
                    end
                    flipswap = (r_L+x(1)+x(2)+x(3) < rnd_cmp & bd);
                    if sum(flipswap)>0
                        state.steps.flip_swap = state.steps.flip_swap + sum(flipswap);
                        state = flip_swap_HMC(state,bd);
                    end
            end
        end

        % slightly randomize the momentum
         N1 = randn( szd, szb );      
%        N1 = repmat(randn(szd,1),1,szb);
        state.V1  = real(sqrt(1-beta)) * state.V1 + sqrt(beta) * N1; % numerical errors if beta == 1
%         %maybe for v2
        if flip_on_rej == 2
            N2 = randn( szd, szb );
            state.V2  = real(sqrt(1-beta)) * state.V2 + sqrt(beta) * N2; % numerical errors if beta == 1
            state.V2 = N2;
        end
        state.steps.total = state.steps.total + szb;    
    end
    
    state.funcevals = state.funcevals + funcevals_inc/szb;
    
    X = state.X;
end

% to process the fields in our options structure
% this function taken from Mark Schmidt's minFunc
% http://www.cs.ubc.ca/~schmidtm/Software/minFunc.html
function [v] = getField(options,opt,default)
options = toUpper(options); % make fields case insensitive
opt = upper(opt);
if isfield(options,opt)
    if ~isempty(getfield(options,opt))
        v = getfield(options,opt); 
    else
        v = default;
    end
else
    v = default;
end
end
function [o] = toUpper(o)
if ~isempty(o)
    fn = fieldnames(o);
    for i = 1:length(fn)
        o = setfield(o,upper(fn{i}),getfield(o,fn{i}));
    end
end
end

%%function that describes the Flipping Operation
function [state] = flip_HMC(state,ind)
if nargin < 2
    ind = 1:size(state.V1,2);
end
state.V1(:,ind) = -state.V1(:,ind);
if isfield(state,{'V2'})
    state.V2(:,ind) = -state.V2(:,ind);
end
end


%%%should return state
function [state] = leap_HMC(state,ind,opts,varargin)
global funcevals_inc

if isempty(ind)
    ind = (ones(size(state.V1,2),1)>0);
end

f_E = getField( opts, 'E', 0 );
f_dEdX = getField( opts, 'dEdX', 0 );
% dut = 0.5; % fraction of the momentum to be replaced per unit time
epsilon = getField( opts, 'epsilon', 0.1 );
LeapSize = getField(opts, 'LeapSize',1);


% run a single Langevin dynamics step.
% TODO: make this a variable number of leapfrog steps
%%USE LEAPSIZE here to do stuffs
V0 = state.V1; V0(:) = 0;
X0 = state.X; X0(:) = 0;
E0 = state.E; E0(:) = 0;
V1 = state.V1; V1(:) = 0;
X1 = state.X; X1(:) = 0;
E1 = state.E; E1(:) = 0;

for ii=1:LeapSize
    funcevals_inc = funcevals_inc + sum(ind);
    
    assert(max(ind) < 2);
    
    V0(:,ind) = state.V1(:,ind);
    X0(:,ind) = state.X(:,ind);
    E0(:,ind) = state.E(:,ind);
    dEdX0(:,ind) = state.dEdX(:,ind);
    Vhalf(:,ind) = V0(:,ind) - epsilon/2 * dEdX0(:,ind);    
    X1(:,ind) = X0(:,ind) + epsilon * Vhalf(:,ind);
    dEdX1(:,ind) = f_dEdX( X1(:,ind), varargin{:} );
    E1(:,ind) = f_E( X1(:,ind), varargin{:});
    V1(:,ind) = Vhalf(:,ind) - epsilon/2 * dEdX1(:,ind);
    state.V1(:,ind) = V1(:,ind);
    % fprintf('v0 ')
    % V0(:,1)'
    % fprintf('v1 ')
    % V1(:,1)'
    % fprintf('dedx0 ')
    % dEdX0(:,1)'
    % fprintf('dedx1 ')
    % dEdX1(:,1)'
    % fprintf('x0 ')
    % X0(:,1)'
    % fprintf('x1 ')
    % X1(:,1)'
    state.X(:,ind) = X1(:,ind);
    state.E(:,ind) = E1(:,ind);
    state.dEdX(:,ind) = dEdX1(:,ind);
end
end


function [state] = swap_HMC(state,ind)
if nargin < 2
    ind = 1:size(state.V1,2);
end
%first init tmp
tmp = state.V2; tmp(:)=0;
%copy over only the indices that need swapping
tmp(:,ind) = state.V2(:,ind);
state.V2(:,ind)= state.V1(:,ind);
state.V1(:,ind) = tmp(:,ind);
end

% I'll implement FS as a function
function [state] = flip_swap_HMC(state,ind)
if nargin < 2
    ind = 1:size(state.V1,2);
end
state = flip_HMC(state,ind);
state = swap_HMC(state,ind);
end

%function to evaluate hamiltonian of a state
%%Use a buffer 
% TODO(jascha) naming scheme -- potential to energy and/or log_probability
function [H] = hamiltonian_HMC(state,ind,flip_on_rej)
if isempty(ind)
    ind = 1:size(state.V1,2);
end
E = state.E(:,ind);
V1 = state.V1(:,ind);
if flip_on_rej ==2
    V2 = state.V2(:,ind);
%     potential = E + (1/2) * (V1'*V1) + (1/2) * (V2'*V2);    
    %to generalize this needs to be sum(v1.*v1)
    H = E + (1/2) * (sum(V1.*V1)) + (1/2) * (sum(V2.*V2));
else
%     potential = E + (1/2) * (V1'*V1);
    H = E + (1/2) * (sum(V1.*V1));
end
% %negate the energy so you can just exponentiate directly
% potential = -potential;
end

function [prob, resid, cumu] = leap_prob_recurse(varargin)
    % returns [prob making this transition], [residual probability], [cumulative probability of any transition]
     state = varargin;
    if size(state,2) == 2
        prob = leap_prob( state{1}, state{2}, 3 );
        cumu = prob;
        resid = 1 - prob;
        return;
    end
       
    [~, residual_forward, cumulative_forward] = leap_prob_recurse(state{1:end-1});
    [~, residual_reverse, cumulative_reverse] = leap_prob_recurse(state{end:-1:2});
    start_state_ratio = exp(hamiltonian_HMC(state{1},[],3) - hamiltonian_HMC(state{end},[],3));
    
    prob = min([residual_forward; residual_reverse.*start_state_ratio], [], 1);
    cumu = cumulative_forward + prob;
    resid = 1 - cumu;    
end

%
function [prob] = leap_prob(start_state, leap_state,flip_on_rej)

% numerator = hamiltonian_HMC(leap_state,[],flip_on_rej);
% denominator = hamiltonian_HMC(start_state,[],flip_on_rej);
% prob = min(1,exp(numerator - denominator));
H_leap = hamiltonian_HMC(leap_state,[],flip_on_rej);
H_start = hamiltonian_HMC(start_state,[],flip_on_rej);
prob = min(1,exp(H_start - H_leap));

end
