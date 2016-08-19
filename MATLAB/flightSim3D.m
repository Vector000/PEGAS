%flightSim3D.m
%Complete 3DoF flight simulation in Cartesian coordinates.
%Pass vehicle parameters in 'vehicle' struct. Pass initial conditions in
%'init' struct (see section 'simulation initialization' for details, true
%documentation is TODO for now). Pass control method in 'control' struct
%(see 'control setup' section for details) - supports a natural gravity
%turn simulation, predefined pitch program, PEG pitch guidance and unguided
%free flight. NO yaw steering.
%Vehicle is modelled as a point mass with drag. Simulation is located in an
%Earth-centered, inertial frame of reference, so in launch simulations the
%vehicle does not begin stationary (unless on a pole). No vehicle details
%are assumed, engine is modelled only using thrust and Isp with no regard
%for actual number or type of engines. RO atmosphere is modelled. No AoA or
%lift effects are taken into account.
function [results] = flightSim3D(vehicle, initial, control, dt)
    %declare globals
    global mu; global g0; global R;
    global atmpressure; global atmtemperature;
    
    %VEHICLE UNPACK
    m = vehicle.m0;
    isp0 = vehicle.i0;
    isp1 = vehicle.i1;
    dm = vehicle.dm;
    maxT = vehicle.mt;
    engT = vehicle.et;
    area = vehicle.ra;
    drag = vehicle.dc;
    
    %CONTROL SETUP
    if control.type == 0
        %type 0 = natural gravity turn simulation
        gtiP = control.p;   %initial pitchover angle for gravity turn
        gtiV = control.v;   %velocity at which the pitchover begins
        GT = 0; %gravity turn status flag:
                    %0 - not begun yet;
                    %1 - equaling to flight angle;
                    %2 - match flight angle
        ENG = -1;
    elseif control.type == 1
        %type 1 = pitch program control, constant azimuth
        prog = control.program;
        azim = control.azimuth; %for now only constant, no programming
        ENG = -1;
    elseif control.type == 2
        %type 2 = powered explicit guidance
        target = control.target*1000+R; %target orbit altitude
        azim = control.azimuth;         %YAW CONTROL COMING SOON
        ct = control.major;             %length of the major loop
        lc = 0;                         %time since last PEG cycle
        ENG = 1;                        %engine state flag:
                                            %0 - fuel deprived;
                                            %1 - running;
                                            %2 - cut as scheduled by PEG
    elseif control.type == 3
        %type 3 = experimental UPFG
        target = control.target;        %whole data structure as given
        ct = control.major;
        lc = 0;
        ENG = 1;
    elseif control.type == 5
        %type 5 = coast phase (unguided free flight)
        %strongly recommended using initial.type==1
        engT = 0;
        maxT = control.length;
        ENG = -1;
    end;
    
    %SIMULATION SETUP
    m = m - engT*dm;    %rocket is burning fuel while bolted to the launchpad for engT seconds before it's released
    maxT = maxT - engT; %this results in loss of propellant mass and hence reduction of maximum burn time
    N = floor(maxT/dt)+1;%simulation steps
    t = zeros(N,1);     %simulation time
    F = zeros(N,1);     %thrust magnitude [N]
    acc = zeros(N,1);   %acceleration due to thrust magnitude [m/s^2]
    q = zeros(N,1);     %dynamic pressure [Pa]
    pitch = zeros(N,1); %pitch command log [deg] (0 - straight up)
    yaw = zeros(N,1);   %yaw command log [deg] (0 - straight East, 90 - North)
    g_loss = 0;         %gravity d-v losses [m/s]
    d_loss = 0;         %drag d-v losses [m/s]
    %vehicle position in cartesian XYZ frame
    r = zeros(N,3);     %from Earth's center [m]
    rmag = zeros(N,1);  %magnitude [m]
    %vehicle velocity
    v = zeros(N,3);     %relative to Earth's center [m/s]
    vmag = zeros(N,1);  %magnitude [m/s]
    vy = zeros(N,1);    %magnitude - altitude change [m/s]
    vt = zeros(N,1);    %magnitude - tangential [m/s]
    vair = zeros(N,3);  %relavite to surface [m/s]
    vairmag = zeros(N,1);%magnitude relative to surface [m/s]
    %reference frame matrices
    nav = zeros(3,3);   %KSP-style navball frame (radial, North, East)
    rnc = zeros(3,3);   %PEG-style tangential frame (radial, normal, circumferential)
    %flight angles
    ang_p_srf = zeros(N,1); %flight pitch angle, surface related
    ang_y_srf = zeros(N,1); %flight yaw angle, surface related
    ang_p_obt = zeros(N,1); %flight pitch angle, orbital (absolute)
    ang_y_obt = zeros(N,1); %flight yaw angle, orbital (absolute)
    
    %SIMULATION INITIALIZATION
    if initial.type==0      %launch from static site
        %btw, wonder what would happen if one wanted to launch from the North Pole :D
        [r(1,1),r(1,2),r(1,3)] = sph2cart(degtorad(initial.lon), degtorad(initial.lat), R+initial.alt);
        v(1,:) = surfSpeedInit(r(1,:));
    elseif initial.type==1  %vehicle already in flight
        t(1) = initial.t;
        r(1,:) = initial.r;
        v(1,:) = initial.v;
    else
        disp('Wrong initial conditions!');
        return;
    end;
    rmag(1) = norm(r(1,:));
    vmag(1) = norm(v(1,:));
    nav = getNavballFrame(r(1,:), v(1,:));
    rnc = getCircumFrame(r(1,:), v(1,:));
    vair(1,:) = v(1,:) - surfSpeed(r(1,:), nav);
    vairmag(1) = max(norm(vair(1)),1);
    vy(1) = dot(v(1,:),nav(1,:));
    vt(1) = dot(v(1,:),rnc(3,:));
    ang_p_srf(1) = acosd(dot(unit(vair(1,:)),nav(1,:)));
    ang_y_srf(1) = acosd(dot(unit(vair(1,:)),nav(3,:)));
    ang_p_obt(1) = acosd(dot(unit(v(1,:)),nav(1,:)));
    ang_y_obt(1) = acosd(dot(unit(v(1,:)),nav(3,:)));
    
    %PEG SETUP
    if control.type==2
        dbg = zeros(N,4);   %debug log (A, B, C, T)
        p = approxFromCurve((rmag(1)-R)/1000, atmpressure);
        isp = (isp1-isp0)*p+isp0;
        ve = isp*g0;
        acc(1) = ve*dm/m;
        [A, B, C, T] = poweredExplicitGuidance(...
                        0,...
                        rmag(1), vt(1), vy(1), target,...
                        acc(1), ve, 0, 0, maxT);
        dbg(1,:) = [A, B, C, T];
        pitch(1) = acosd(A + C);
        yaw(1) = 90-azim;
    elseif control.type==3
        %below 3 lines just to avoid 0 acceleration point in plots
        p = approxFromCurve((rmag(1)-R)/1000, atmpressure);
        isp = (isp1-isp0)*p+isp0;
        acc(1) = isp*g0*dm/m;
        upfg_vehicle = struct('thrust', isp0*g0*dm, 'isp', isp0, 'mass', m);
        upfg_state = struct('time', t(1), 'mass', m, 'radius', r(1,:), 'velocity', v(1,:));
        %guidance initialization, Rd by projection of current R onto target plane
        rdinit = r(1,:) - dot(r(1,:),target.normal)*target.normal;
        ix = rdinit/norm(rdinit);
        %rdinit = ix*target.radius;
        iz = cross(ix,target.normal);
        rdinit = ix+iz;
        rdinit = rdinit/norm(rdinit);
        rdinit = target.radius*rdinit;
        vangle = [sind(target.angle);0;cosd(target.angle)];
        vdinit = target.velocity*([ix;target.normal;iz]*vangle)' - v(1,:);
        cser = struct('dtcp', 0, 'xcp', 0, 'A', 0, 'D', 0, 'E', 0);
        upfg_internal = struct('cser', cser, 'tgo', 1, 'rbias', [0,0,0],...
                               'rd', rdinit, 'rgrav', (mu/2)*r(1,:)/norm(r(1,:))^3,...
                               'vgo', vdinit, 'v', v(1,:));
        dbg = debugInitializator(floor(maxT/ct)+5);
        for i=1:5   %TODO: implement a convergence check
            [upfg_internal, guidance, debug] = unifiedPoweredFlightGuidance(...
                               upfg_vehicle, target, upfg_state, upfg_internal);
            dbg = debugAggregator(dbg, debug);
        end;
        pitch(1) = guidance.pitch;
        yaw(1) = guidance.yaw;
    end;
    
    %MAIN LOOP
    for i=2:N
        %PITCH CONTROL
        if control.type == 0
            %natural, lock-prograde gravity turn
            %state control
            if dot(v(i-1,:), nav(1,:)) >= gtiV && GT == 0
                %vertical velocity condition matched
                GT = 1;
            elseif ang_p_srf(i-1) > gtiP && GT == 1
                %(surface) initial pitch angle reached
                GT = 2;
            end;
            %pitch control depending on state
            if GT == 0
                %vertical flight, velocity buildup
                pitch(i) = 0;
            elseif GT == 1
                %pitching over to a given angle
                pitch(i) = min(pitch(i-1)+dt, gtiP);    %hardcoded 1deg/s change (to simulate real, not instantaneous pitchover)
            else
                %pitch angle matching airspeed (thrust prograde)
                pitch(i) = ang_p_srf(i-1);
            end;
        elseif control.type == 1
            %pitch program control, with possible yaw control too
            pitch(i) = approxFromCurve(t(i-1), prog);
            yaw(i) = 90-azim;
        elseif control.type == 2
            %PEG pitch control
            %check if there's still fuel
            if (t(i-1)-t(1) > maxT && ENG > 0)
                ENG = 0;    %engine ran out of fuel
                break;      %exit the main simulation loop
            end;
            %check how long ago was the last PEG cycle
            if (lc < ct-dt)
                %if not too long ago - increment
                lc = lc + dt;
            else
                %run PEG
                [A, B, C, T] = poweredExplicitGuidance(...
                                0,...
                                rmag(i-1), vt(i-1), vy(i-1), target,...
                                acc(i-1), ve, A, B, T); %passing old T instead of T-dt IS CORRECT
                lc = 0; %TODO: bypass resetting this one if PEG skipped AB recalculation
            end;
            %PEG debug logs
            dbg(i,1) = A;
            dbg(i,2) = B;
            dbg(i,3) = C;
            dbg(i,4) = T;
            %PEG-scheduled cutoff
            if (T-lc < dt && ENG == 1)
                ENG = 2;
                break;
            end;
            %pitch control (clamped to acosd domain which should never be necessary)
            pitch(i) = acosd( min(1, max(-1, A - B*lc + C)) );
            yaw(i) = 90-azim;
        elseif control.type == 3
            %UPFG pitch&yaw control
            %check if there's still fuel
            if (t(i-1)-t(1) > maxT && ENG > 0)
                ENG = 0;    %engine ran out of fuel
                break;      %exit the main simulation loop
            end;
            %check how long ago was the last PEG cycle
            if (lc < ct-dt)
                %if not too long ago - increment
                lc = lc + dt;
            else
                %run PEG
                upfg_state.time     = t(i-1);
                upfg_state.mass     = m;
                upfg_state.radius   = r(i-1,:);
                upfg_state.velocity = v(i-1,:);
                [upfg_internal, guidance, debug] = unifiedPoweredFlightGuidance(...
                               upfg_vehicle, target, upfg_state, upfg_internal);
                dbg = debugAggregator(dbg, debug);
                lc = 0;
            end;
            %PEG-scheduled cutoff
            if (guidance.tgo-lc < dt && ENG == 1)
                ENG = 2;
                break;
            end;
            %TEMP VELOCITY-DRIVEN CUTOFF
            if (norm(v(i-1,:))>=target.velocity)
                ENG = 3;
                break;
            end;
            %pitch&yaw control
            pitch(i) = guidance.pitch;
            yaw(i)   = guidance.yaw;
            if guidance.tgo < -20
                pitch(i) = pitch(i-1);
                yaw(i) = yaw(i-1);
            end;
        end;
        
        %PHYSICS
        %thrust/acceleration
        p = approxFromCurve((rmag(i-1)-R)/1000, atmpressure);
        isp = (isp1-isp0)*p+isp0;
        %enable coast flight
        if control.type==5
            F(i) = 0;
        else
            F(i) = isp*g0*dm;
        end;
        acc(i) = F(i)/m;
        acv = acc(i)*makeVector(nav, pitch(i), yaw(i));
        %gravity
        G = mu*r(i-1,:)/norm(r(i-1,:))^3;           %acceleration [m/s^2]
        g_loss = g_loss + norm(G)*dt;               %integrate gravity losses
        %drag
        cd = approxFromCurve(vairmag(i-1), drag);   %drag coefficient
        temp = approxFromCurve((rmag(i-1)-R)/1000, atmtemperature)+273.15;
        dens = calculateAirDensity(p*101325, temp);
        q(i) = 0.5*dens*vairmag(i-1)^2;             %dynamic pressure
        D = area*cd*q(i)/m;                         %drag-induced acceleration [m/s^2]
        d_loss = d_loss + D*dt;                     %integrate drag losses
        %absolute velocities
        v(i,:) = v(i-1,:) + acv*dt - G*dt - D*unit(vair(i-1,:))*dt;
        vmag(i) = norm(v(i,:));
        vy(i) = dot(v(i,:),nav(1,:));
        vt(i) = dot(v(i,:),rnc(3,:));
        %position
        r(i,:) = r(i-1,:) + v(i,:)*dt;
        rmag(i) = norm(r(i,:));
        %local reference frames
        nav = getNavballFrame(r(i,:), v(i,:));
        rnc = getCircumFrame(r(i,:), v(i,:));
        %surface velocity (must be here because needs reference frames)
        vair(i,:) = v(i,:) - surfSpeed(r(i,:), nav);
        vairmag(i) = norm(vair(i,:));
        if vairmag(i)==0    %since we later divide by this and in first iteration it can be zero
            vairmag(i) = 1; %do we need this any longer, after introducint unit()
        end;
        %angles
        ang_p_srf(i) = acosd(dot(unit(vair(i,:)),nav(1,:)));
        ang_y_srf(i) = acosd(dot(unit(vair(i,:)),nav(3,:)));
        ang_p_obt(i) = acosd(dot(unit(v(i,:)),nav(1,:)));
        ang_y_obt(i) = acosd(dot(unit(v(i,:)),nav(3,:)));
        %MASS&TIME
        m = m - dm*dt;
        t(i) = t(i-1) + dt;
    end;
    
    %OUTPUT
    plots = struct('t', t(1:i-1),...
                   'r', r(1:i-1,:),...
                   'rmag', rmag(1:i-1),...
                   'v', v(1:i-1,:),...
                   'vy', vy(1:i-1),...
                   'vt', vt(1:i-1),...
                   'vmag', vmag(1:i-1),...
                   'F', F(1:i-1),...
                   'a', acc(1:i-1),...
                   'q', q(1:i-1),...
                   'pitch', pitch(1:i-1),...
                   'yaw', yaw(1:i-1),...
                   'angle_ps', ang_p_srf(1:i-1),...
                   'angle_ys', ang_y_srf(1:i-1),...
                   'angle_po', ang_p_obt(1:i-1),...
                   'angle_yo', ang_y_obt(1:i-1));
    %add debug data if created
    if exist('dbg', 'var')==1
        plots().DEBUG = dbg;
    end;
    orbit = struct('SMA', 0, 'ECC', 0, 'INC', 0,...
                   'LAN', 0, 'AOP', 0, 'TAN', 0);
    results = struct('Altitude', (rmag(i-1)-R)/1000,...
                     'Apoapsis', 0, 'Periapsis', 0,...
                     'Orbit', orbit,...
                     'Velocity', vmag(i-1),...
                     'VelocityY', dot(v(i-1,:), nav(1,:)),...
                     'VelocityT', dot(v(i-1,:), rnc(3,:)),...
                     'maxQv', 0, 'maxQt', 0,...
                     'LostGravity', g_loss,...
                     'LostDrag', d_loss,...
                     'LostTotal', g_loss+d_loss,...
                     'BurnTimeLeft', maxT-t(i-1)+t(1),...
                     'Plots', plots, 'ENG', ENG);
    [results.Apoapsis, results.Periapsis, results.Orbit.SMA,...
                    results.Orbit.ECC, results.Orbit.INC,...
                    results.Orbit.LAN, results.Orbit.AOP,...
                    results.Orbit.TAN] = getOrbitalElements(r(i-1,:), v(i-1,:));
    [results.maxQt, results.maxQv] = getMaxValue(q');   %get time and value of maxQ
    results.maxQt = t(results.maxQt);                   %format maxQ time to seconds
end

%constructs a local reference frame, KSP-navball style
function [f] = getNavballFrame(r, v)
    %pass current position under r (1x3)
    %current velocity under v (1x3)
    pseudo_up = unit([r(1) r(2) 0]);
    pseudo_north = cross([r(1) r(2) 0],[v(1) v(2) 0]);
    pseudo_north = unit(pseudo_north);
    east = cross(pseudo_north,pseudo_up);   %true East direction
    up = unit(r);                   %true Up direction (radial away from Earth)
    north = cross(up, east);        %true North direction (completes frame)
    f = zeros(3,3);
    %return a right-handed coordinate system base
    f(1,:) = up;
    f(2,:) = north;
    f(3,:) = east;
end

%constructs a local reference frame in style of PEG coordinate base
function [f] = getCircumFrame(r, v)
    %pass current position under r (1x3)
    %current velocity under v (1x3)
    radial = unit(r);               %Up direction (radial away from Earth)
    normal = cross(r, v);
    normal = unit(normal);          %Normal direction (perpendicular to orbital plane)
    circum = cross(normal, radial); %Circumferential direction (tangential to sphere, in motion plane)
    f = zeros(3,3);
    %return a left(?)-handed coordinate system base
    f(1,:) = radial;
    f(2,:) = normal;
    f(3,:) = circum;
end

%finds rotation angle between the two frames
function [alpha] = rnc2nav(rnc, nav)
    %pass reference frame matrices
    %by their definitions, their 'radial' component is the same, therefore
    %rotation between them can be described with a single number
    alpha = dot(rnc(3,:), nav(3,:));
end

%constructs a unit vector in the global frame for a given azimuth/elevation
%angles in a given frame (first angle ('p') rotates from frame's first
%towards second vector, second ('y') rotates from second towards third)
function [v] = makeVector(frame, p, y)
    V = zeros(3,3);
    V(1,:) = cosd(p)*frame(1,:);
    V(2,:) = sind(p)*sind(y)*frame(2,:);
    V(3,:) = sind(p)*cosd(y)*frame(3,:);
    v = V(1,:) + V(2,:) + V(3,:);
end

%finds Earth's rotation velocity vector at given cartesian location using
%no velocity vector (meant for rotational velocity initilization)
function [rot] = surfSpeedInit(r)
%    global R;
    %create temporary frame by generating a dummy velocity vector
    t = r*[0 1 0; -1 0 0; 0 0 1];   %90 degrees counterclockwise around Z axis, looking down
    f = getNavballFrame(r, t);      %temp frame
    rot = surfSpeed(r, f);          %use a standard function
end

%finds Earth's rotation velocity vector at given cartesian location
%assuming a navball reference frame is available
function [rot] = surfSpeed(r, nav)
    global R;
    [~,lat,~] = cart2sph(r(1), r(2), r(3));
    vel = 2*pi*R/(24*3600)*cos(lat);
    rot = vel*nav(3,:); %third componend is East vector
end

function [v] = unit(vector)
    if norm(vector)==0
        v = vector;
    else
        v = vector/norm(vector);
    end;
end

%initializes UPFG debug data aggregator with zero vectors of appropriate sizes
%pass expected length of the vector (number of guidance iterations, usually
%maxT / guidance cycle + 5 should be okay)
function [a] = debugInitializator(n)
    a = struct('THIS', 0,...
               'time', zeros(n,1),...
               'dvsensed', zeros(n,4),...
               'vgo1', zeros(n,4),...
               'L1', zeros(n,1),...
               'tgo', zeros(n,1),...
               'L', zeros(n,1),...
               'J', zeros(n,1),...
               'S', zeros(n,1),...
               'Q', zeros(n,1),...
               'P', zeros(n,1),...
               'H', zeros(n,1),...
               'lambda', zeros(n,4),...
               'rgrav1', zeros(n,4),...
               'rgo1', zeros(n,4),...
               'iz1', zeros(n,4),...
               'rgoxy', zeros(n,4),...
               'rgoz', zeros(n,1),...
               'rgo2', zeros(n,4),...
               'lambdadot', zeros(n,4),...
               'iF', zeros(n,4),...
               'phi', zeros(n,1),...
               'phidot', zeros(n,1),...
               'vthrust', zeros(n,4),...
               'rthrust', zeros(n,4),...
               'vbias', zeros(n,4),...
               'rbias', zeros(n,4),...
               'pitch', zeros(n,1),...
               'iF_up', zeros(n,4),...
               'iF_plane', zeros(n,4),...
               'EAST', zeros(n,4),...
               'yaw', zeros(n,1),...
               'rc1', zeros(n,4),...
               'vc1', zeros(n,4),...
               'rc2', zeros(n,4),...
               'vc2', zeros(n,4),...
               'cser_dtcp', zeros(n,1),...
               'cser_xcp', zeros(n,1),...
               'cser_A', zeros(n,1),...
               'cser_D', zeros(n,1),...
               'cser_E', zeros(n,1),...
               'vgrav', zeros(n,4),...
               'rgrav2', zeros(n,4),...
               'rp', zeros(n,4),...
               'rd', zeros(n,4),...
               'ix', zeros(n,4),...
               'iz2', zeros(n,4),...
               'vd', zeros(n,4),...
               'vgop', zeros(n,4),...
               'dvgo', zeros(n,4),...
               'vgo2', zeros(n,4));
end

%handles UPFG debug data aggregating
%adds debug data from a single guidance iteration into aggregated, time-based
%struct of vectors
%pass initialized debug structure and UPFG debug output
function [a] = debugAggregator(a, d)
    %we must know where to put the new results
    i = a.THIS + 1;
    a.THIS = i;
    %and onto the great copy...
    a.time(i) = d.time;
    a.dvsensed(i,1:3) = d.dvsensed;
    a.dvsensed(i,4) = norm(d.dvsensed);
    a.vgo1(i,1:3) = d.vgo1;
    a.vgo1(i,4) = norm(d.vgo1);
    a.L1(i) = d.L1;
    a.tgo(i) = d.tgo;
    a.L(i) = d.L;
    a.J(i) = d.J;
    a.S(i) = d.S;
    a.Q(i) = d.Q;
    a.P(i) = d.P;
    a.H(i) = d.H;
    a.lambda(i,1:3) = d.lambda;
    a.lambda(i,4) = norm(d.lambda);
    a.rgrav1(i,1:3) = d.rgrav1;
    a.rgrav1(i,4) = norm(d.rgrav1);
    a.rgo1(i,1:3) = d.rgo1;
    a.rgo1(i,4) = norm(d.rgo1);
    a.iz1(i,1:3) = d.iz1;
    a.iz1(i,4) = norm(d.iz1);
    a.rgoxy(i,1:3) = d.rgoxy;
    a.rgoxy(i,4) = norm(d.rgoxy);
    a.rgoz(i) = d.rgoz;
    a.rgo2(i,1:3) = d.rgo2;
    a.rgo2(i,4) = norm(d.rgo2);
    a.lambdadot(i,1:3) = d.lambdadot;
    a.lambdadot(i,4) = norm(d.lambdadot);
    a.iF(i,1:3) = d.iF;
    a.iF(i,4) = norm(d.iF);
    a.phi(i) = d.phi;
    a.phidot(i) = d.phidot;
    a.vthrust(i,1:3) = d.vthrust;
    a.vthrust(i,4) = norm(d.vthrust);
    a.rthrust(i,1:3) = d.rthrust;
    a.rthrust(i,4) = norm(d.rthrust);
    a.vbias(i,1:3) = d.vbias;
    a.vbias(i,4) = norm(d.vbias);
    a.rbias(i,1:3) = d.rbias;
    a.rbias(i,4) = norm(d.rbias);
    a.pitch(i) = d.pitch;
    a.iF_up(i,1:3) = d.iF_up;
    a.iF_up(i,4) = norm(d.iF_up);
    a.iF_plane(i,1:3) = d.iF_plane;
    a.iF_plane(i,4) = norm(d.iF_plane);
    a.EAST(i,1:3) = d.EAST;
    a.EAST(i,4) = norm(d.EAST);
    a.yaw(i) = d.yaw;
    a.rc1(i,1:3) = d.rc1;
    a.rc1(i,4) = norm(d.rc1);
    a.vc1(i,1:3) = d.vc1;
    a.vc1(i,4) = norm(d.vc1);
    a.rc2(i,1:3) = d.rc2;
    a.rc2(i,4) = norm(d.rc2);
    a.vc2(i,1:3) = d.vc2;
    a.vc2(i,4) = norm(d.vc2);
    a.cser_dtcp(i) = d.cser.dtcp;
    a.cser_xcp(i) = d.cser.xcp;
    a.cser_A(i) = d.cser.A;
    a.cser_D(i) = d.cser.D;
    a.cser_E(i) = d.cser.E;
    a.vgrav(i,1:3) = d.vgrav;
    a.vgrav(i,4) = norm(d.vgrav);
    a.rgrav2(i,1:3) = d.rgrav2;
    a.rgrav2(i,4) = norm(d.rgrav2);
    a.rp(i,1:3) = d.rp;
    a.rp(i,4) = norm(d.rp);
    a.rd(i,1:3) = d.rd;
    a.rd(i,4) = norm(d.rd);
    a.ix(i,1:3) = d.ix;
    a.ix(i,4) = norm(d.ix);
    a.iz2(i,1:3) = d.iz2;
    a.iz2(i,4) = norm(d.iz2);
    a.vd(i,1:3) = d.vd;
    a.vd(i,4) = norm(d.vd);
    a.vgop(i,1:3) = d.vgop;
    a.vgop(i,4) = norm(d.vgop);
    a.dvgo(i,1:3) = d.dvgo;
    a.dvgo(i,4) = norm(d.dvgo);
    a.vgo2(i,1:3) = d.vgo2;
    a.vgo2(i,4) = norm(d.vgo2);
end
