function DataProcessingGUI
% DATAPROCESSINGGUI
% -------------------------------------------------------------------------
% Thesis/GitHub processing interface for CZT gamma/neutron detector data.
%
% Purpose
%   This GUI processes calibration-source and neutron-exposure list-mode maps
%   from the CZT detector workflow. It performs background subtraction, optional
%   averaging of two background acquisitions, 1D spectrum generation, pixel-wise
%   peak inspection, pixel gain correction, energy calibration, energy-resolution
%   (FWHM) estimation,
%   calibration-curve plotting, and export of processed spectra/maps.
%
% Required input MAT variables
%   Background and calibration files:
%       LMmap_noEcorrect   [pixels x channels] counts before energy correction
%       LMmap_Ecorrect     [pixels x channels] counts after energy correction
%
%   Neutron-exposure files:
%       LMmap_noEcorrect   [pixels x channels] neutron-exposure counts
%       LMmap_Ecorrect     [pixels x channels] neutron-exposure counts
%
% Main processing equations
%   Background subtraction:
%       C_corr(p,ch) = C_raw(p,ch) - C_bg(p,ch)
%
%   If two background files are selected:
%       C_bg(p,ch) = (C_bg1(p,ch) + C_bg2(p,ch))/2
%
%   Spectrum formation:
%       S(ch) = sum_p C_corr(p,ch)
%
%   Linear energy calibration:
%       E(ch) = m*ch + b
%       m = (E2 - E1)/(ch2 - ch1)
%       b = E1 - m*ch1
%
%   Energy resolution:
%       Resolution (%) = 100*FWHM/E_peak
%
% Physics assumptions
%   1. Background and signal acquisitions are compatible in acquisition time,
%      detector settings, threshold settings, and channel/binning structure.
%   2. Subtracting the background map pixel-by-pixel is valid for the selected
%      measurement set. If exposure times differ, normalize counts before using
%      this GUI.
%   3. The calibration is modeled as linear over the selected energy range.
%   4. Smoothing is applied only for visualization and peak/FWHM estimation;
%      exported corrected maps remain count data after background subtraction.
%   5. Negative values after background subtraction are clipped only in plotted
%      spectra; the stored corrected maps preserve signed differences unless
%      explicitly saved as processed display spectra.
%   6. The tab labelled pixel gain correction is not a geometric image
%      registration step. It refers to correction of pixel-to-pixel spectral
%      gain variation by comparing photopeak locations across detector pixels.
%
% MATLAB/toolbox requirements
%   MATLAB R2020b or later recommended.
%   Required: MATLAB App/UI components (uifigure/uiaxes/uitabgroup).
%   Recommended: Signal Processing Toolbox for the optional filtfilt smoother.
%   The default smoothing path uses smoothdata where available.
%
% Author/maintenance note
%   Prepared for thesis data processing and online sharing. Keep filenames and
%   function names matched when renaming this file.
% -------------------------------------------------------------------------

fig = uifigure('Name','Data Processing GUI','Position',[60 60 1280 780]);
tg  = uitabgroup(fig,'Position',[10 10 1260 760]);

t1 = uitab(tg,'Title','File Loader');
t2 = uitab(tg,'Title','Uncorrected Spectra');
t3 = uitab(tg,'Title','Pixel Gain Correction');
t4 = uitab(tg,'Title','Energy Correction & FWHM');
t5 = uitab(tg,'Title','Calibration Plot');
t6 = uitab(tg,'Title','Neutron Exposure');

% ---- shared state ----
S = struct();
S.COLORS = struct('noE',[0 0.4470 0.7410],'E',[0.8500 0.3250 0.0980]);
S.path   = pwd;
S.calQuick = [];
S.calFinal = [];
setappdata(fig,'S',S);

%% ===================  TAB 1 : loader  ===================
x = 24; yTop = 640; dy = 58; wLbl = 170; wCtl = 140; wBtn = 130;

uilabel(t1,'Text','Energy Mode:','Position',[x yTop wLbl 22]);
ddMode = uidropdown(t1,'Items',{'LEM','HEM'},'Value','LEM', ...
    'Position',[x+wLbl+6 yTop wCtl 24], 'ValueChangedFcn',@(~,~)modeChanged());
yTop = yTop-dy;

uilabel(t1,'Text','Calibration Source Isotope:','Position',[x yTop wLbl+60 22]);
ddIso = uidropdown(t1,'Items',{'Co-57','Am-241','Eu-152'},'Value','Co-57', ...
    'Position',[x+wLbl+66 yTop wCtl 24], 'ValueChangedFcn',@(~,~)isoChanged());

% BG1
yTop = yTop-dy-6;
uilabel(t1,'Text','1) Background 1 (.mat):','Position',[x yTop wLbl+60 22]);
uibutton(t1,'Text','Load BG1','Position',[x+wLbl+220 yTop-2 wBtn 30], ...
    'ButtonPushedFcn',@(~,~)loadBG1());
lblBG1 = uilabel(t1,'Text','Status: Not loaded','Position',[x yTop-28 380 22]);

% BG2
yTop = yTop-dy;
cbBG2 = uicheckbox(t1,'Text','Use Background 2?','Position',[x yTop 160 22], ...
    'ValueChangedFcn',@(~,~)toggleBG2());
btnBG2 = uibutton(t1,'Text','Load BG2','Enable','off', ...
    'Position',[x+wLbl+220 yTop-2 wBtn 30], 'ButtonPushedFcn',@(~,~)loadBG2());
lblBG2 = uilabel(t1,'Text','Status: Not loaded','Position',[x yTop-28 380 22]);

% Calibration source
yTop = yTop-dy;
uilabel(t1,'Text','2) Calibration Source (.mat):','Position',[x yTop wLbl+110 22]);
uibutton(t1,'Text','Load Cal Source','Position',[x+wLbl+220 yTop-2 wBtn+40 30], ...
    'ButtonPushedFcn',@(~,~)loadCal());
lblCal = uilabel(t1,'Text','Status: Not loaded','Position',[x yTop-28 380 22]);

% Neutron file
yTop = yTop-dy;
uilabel(t1,'Text','3) Neutron Exposure (.mat):','Position',[x yTop wLbl+100 22]);
uibutton(t1,'Text','Load Neutron','Position',[x+wLbl+220 yTop-2 wBtn+20 30], ...
    'ButtonPushedFcn',@(~,~)loadNeutron());
lblNeu = uilabel(t1,'Text','Status: Not loaded','Position',[x yTop-28 380 22]);

% Help block
uitextarea(t1,'Editable','off','Position',[560 470 420 170], 'Value', ...
    { 'Smoothing tips:'
      '- moving: span 0.01–0.05 (fast, peak blurring)'
      '- lowess/loess: span 0.01–0.03 (noise removal)'
      '- sgolay: span 0.02–0.05 (best peak shape)'
      'Keep spans modest to avoid negative counts.' });

%% ===================  TAB 2 : Uncorrected Spectra ===================
x2 = 24; y2 = 700; dyy = 44;

% PLOT 1
uilabel(t2,'Text','Plot 1 range [min max] ch:','Position',[x2 y2 190 22]);
edP1min = uieditfield(t2,'numeric','Value',1,'Position',[x2+200 y2 60 22]);
edP1max = uieditfield(t2,'numeric','Value',4096,'Position',[x2+266 y2 60 22]);
y2 = y2-dyy;

uibutton(t2,'Text','Plot Background vs Calibration Source', ...
    'Position',[x2 y2 340 28], 'ButtonPushedFcn',@(~,~)plotBGvCal());
y2 = y2-dyy+8;

uilabel(t2,'Text','Plot 1 smoother:','Position',[x2 y2 120 22]);
ddS1 = uidropdown(t2,'Items',{'moving','loess','lowess','sgolay','filtfilt'}, ...
    'Value','loess','Position',[x2+120 y2 110 22]);
uilabel(t2,'Text','Span:','Position',[x2+236 y2 40 22]);
edS1 = uieditfield(t2,'numeric','Value',0.02,'Position',[x2+276 y2 60 22]);
y2 = y2-dyy;

uibutton(t2,'Text','Apply Smoothing to Plot 1','Position',[x2 y2 340 28], ...
    'ButtonPushedFcn',@(~,~)plotBGvCal(true));
y2 = y2-dyy;

% PLOT 2
uilabel(t2,'Text','Plot 2 range [min max] ch:','Position',[x2 y2 190 22]);
edP2min = uieditfield(t2,'numeric','Value',300,'Position',[x2+200 y2 60 22]);
edP2max = uieditfield(t2,'numeric','Value',1000,'Position',[x2+266 y2 60 22]);
y2 = y2-dyy;

uibutton(t2,'Text','Plot Background-corrected Spectrum (1D)', ...
    'Position',[x2 y2 340 28], 'ButtonPushedFcn',@(~,~)plotCorrected1D(false));
y2 = y2-dyy+8;

uilabel(t2,'Text','Plot 2 smoother:','Position',[x2 y2 120 22]);
ddS2 = uidropdown(t2,'Items',{'moving','loess','lowess','sgolay','filtfilt'}, ...
    'Value','loess','Position',[x2+120 y2 110 22]);
uilabel(t2,'Text','Span:','Position',[x2+236 y2 40 22]);
edS2 = uieditfield(t2,'numeric','Value',0.02,'Position',[x2+276 y2 60 22]);
y2 = y2-dyy;

uibutton(t2,'Text','Apply Smoothing to Plot 2', ...
    'Position',[x2 y2 340 28], 'ButtonPushedFcn',@(~,~)plotCorrected1D(true));
y2 = y2-dyy;

% Quick offset + status
uilabel(t2,'Text','Quick offset (keV):','Position',[x2 y2 140 22]);
edQOff = uieditfield(t2,'numeric','Value',0,'Limits',[-Inf Inf], ...
    'Position',[x2+150 y2 100 22],'ValueChangedFcn',@(~,~)quickOffsetChanged());
y2 = y2-dyy+6;

lblQpk   = uilabel(t2,'Text','','Position',[x2 y2 520 22],'FontColor',[0.05 0.5 0.05]); y2=y2-22;
lblQslope= uilabel(t2,'Text','','Position',[x2 y2 520 22],'FontColor',[0.05 0.5 0.05]); y2=y2-22;
lblQoff  = uilabel(t2,'Text','','Position',[x2 y2 520 22],'FontColor',[0.05 0.5 0.05]); y2=y2-26;
lblQ2pt  = uilabel(t2,'Text','','Position',[x2 y2 520 22],'FontColor',[0.05 0.5 0.05]); y2=y2-26;

% PLOT 3
uilabel(t2,'Text','Plot 3 (energy) range [min max] keV:','Position',[x2 y2 250 22]);
edQemin = uieditfield(t2,'numeric','Value',40,'Position',[x2+255 y2 60 22], ...
    'ValueChangedFcn',@(~,~)plotQuickE1D(false));
edQemax = uieditfield(t2,'numeric','Value',200,'Position',[x2+321 y2 60 22], ...
    'ValueChangedFcn',@(~,~)plotQuickE1D(false));
y2 = y2-dyy;

uibutton(t2,'Text','Plot 3: Quick Energy-Calibrated 1D (before gain correction)', ...
    'Position',[x2 y2 340 28], 'ButtonPushedFcn',@(~,~)plotQuickE1D(false));
y2 = y2-dyy+8;

uilabel(t2,'Text','Plot 3 smoother:','Position',[x2 y2 120 22]);
ddS3 = uidropdown(t2,'Items',{'moving','loess','lowess','sgolay','filtfilt'}, ...
    'Value','loess','Position',[x2+120 y2 110 22]);
uilabel(t2,'Text','Span:','Position',[x2+236 y2 40 22]);
edS3 = uieditfield(t2,'numeric','Value',0.02,'Position',[x2+276 y2 60 22]);
y2 = y2-dyy;

uibutton(t2,'Text','Apply Smoothing to Plot 3','Position',[x2 y2 340 28], ...
    'ButtonPushedFcn',@(~,~)plotQuickE1D(true));
y2 = y2-36;

% Save/Export (NoE context)
uilabel(t2,'Text','File Prefix:','Position',[x2 y2 80 22]);
edPrefix = uieditfield(t2,'text','Value','output','Position',[x2+82 y2 160 22]);
y2 = y2-34;

ySave = y2;
uibutton(t2,'Text','Save BG-corrected data','Position',[x2 ySave 220 28], ...
    'ButtonPushedFcn',@(~,~)saveBGCorr());
lblSave = uilabel(t2,'Text','', ...
    'Position',[x2+230 ySave-36 360 40],'WordWrap','on','FontColor',[0.05 0.5 0.05]);

yExp  = ySave-72;
uibutton(t2,'Text','Export PNGs','Position',[x2 yExp 220 28], ...
    'ButtonPushedFcn',@(~,~)exportTab2());
lblExport2 = uilabel(t2,'Text','', ...
    'Position',[x2+230 yExp-36 360 40],'WordWrap','on','FontColor',[0.05 0.5 0.05]);

% RIGHT axes
axBG1   = uiaxes(t2,'Position',[440 520 800 200]);
title(axBG1,'Background vs Calibration Source (No Energy Correction)');
xlabel(axBG1,'Channel'); ylabel(axBG1,'Counts'); grid(axBG1,'on');

axBG2   = uiaxes(t2,'Position',[440 300 800 190]);
title(axBG2,'Background-corrected Spectrum (1D)');
xlabel(axBG2,'Channel'); ylabel(axBG2,'Counts'); grid(axBG2,'on');

axQuickE = uiaxes(t2,'Position',[440 70 800 200]);
title(axQuickE,'Quick Energy-Calibrated 1D (before gain correction)');
xlabel(axQuickE,'Energy (keV)'); ylabel(axQuickE,'Counts'); grid(axQuickE,'on');

%% ===================  TAB 3 : Pixel Gain Correction ===================
x3 = 24; y3 = 700; d3 = 44;

uilabel(t3,'Text','2D Plot range [min max] ch:','Position',[x3 y3 200 22]);
edP3min = uieditfield(t3,'numeric','Value',1,'Position',[x3+210 y3 60 22]);
edP3max = uieditfield(t3,'numeric','Value',4096,'Position',[x3+276 y3 60 22]);
y3 = y3-d3;

uibutton(t3,'Text','Plot 2D Matrix (No Energy Correction)','Position',[x3 y3 340 28], ...
    'ButtonPushedFcn',@(~,~)plot2D());
y3 = y3-d3;
cbMark = uicheckbox(t3,'Text','Mark max channel per row','Value',true, ...
    'Position',[x3 y3 220 22], 'ValueChangedFcn',@(~,~)plot2D());
y3 = y3-d3+8;

uibutton(t3,'Text','Compute slope/offset (after pixel gain correction)', ...
    'Position',[x3 y3 340 28],'ButtonPushedFcn',@(~,~)computeCalibrationAfterGainCorrection());
y3 = y3-d3+4;
lblAvg   = uilabel(t3,'Text','','Position',[x3 y3 520 22],'FontColor',[0.05 0.5 0.05]); y3=y3-22;

uilabel(t3,'Text','Peak-Pair Calibration Solver','FontWeight','bold','Position',[x3 y3 260 22]);
y3 = y3-30;
uilabel(t3,'Text','Current slope (keV/ch):','Position',[x3 y3 180 22]);
edM0 = uieditfield(t3,'numeric','Value',0,'Limits',[-Inf Inf], ...
    'Position',[x3+190 y3 120 22], 'ValueChangedFcn',@(~,~)applyManualMB());
y3 = y3-34;
uilabel(t3,'Text','Current offset (keV):','Position',[x3 y3 180 22]);
edB0 = uieditfield(t3,'numeric','Value',0,'Limits',[-Inf Inf], ...
    'Position',[x3+190 y3 120 22], 'ValueChangedFcn',@(~,~)applyManualMB());
y3 = y3-34;
uilabel(t3,'Text','Observed peaks (keV):','Position',[x3 y3 150 22]);
edE1obs = uieditfield(t3,'numeric','Value',120.4,'Limits',[-Inf Inf],'Position',[x3+160 y3 100 22]);
edE2obs = uieditfield(t3,'numeric','Value',136.24,'Limits',[-Inf Inf],'Position',[x3+270 y3 100 22]);
y3 = y3-34;
uilabel(t3,'Text','Target energies (keV):','Position',[x3 y3 150 22]);
edE1tar = uieditfield(t3,'numeric','Value',122,'Limits',[-Inf Inf],'Position',[x3+160 y3 100 22]);
edE2tar = uieditfield(t3,'numeric','Value',136,'Limits',[-Inf Inf],'Position',[x3+270 y3 100 22]);
y3 = y3-36;
uibutton(t3,'Text','Compute & Apply slope/offset from peaks', ...
    'Position',[x3 y3 300 28], 'ButtonPushedFcn',@(~,~)solveAndApply());
y3 = y3-26;
lblSolveOut1 = uilabel(t3,'Text','','Position',[x3 y3 520 22],'FontColor',[0.1 0.5 0.2]); y3=y3-22;
lblSolveOut2 = uilabel(t3,'Text','','Position',[x3 y3 520 22],'FontColor',[0.1 0.5 0.2]); y3=y3-22;
lblSolveWarn = uilabel(t3,'Text','','Position',[x3 y3 560 22],'FontColor',[0.7 0.1 0.1]);

axBG3 = uiaxes(t3,'Position',[440 60 800 640]);
title(axBG3,'2D Matrix (No Energy Correction)');
xlabel(axBG3,'Channel'); ylabel(axBG3,'Pixels'); grid(axBG3,'on');

%% ===================  TAB 4 : Energy spectra & FWHM ===================
x4e = 24; y4e = 700; d4e = 48;

uilabel(t4,'Text','Min Energy (keV):','Position',[x4e y4e 150 22]);
edEmin = uieditfield(t4,'numeric','Value',40,'Position',[x4e+150 y4e 120 22]);

y4e = y4e-d4e;
uilabel(t4,'Text','Max Energy (keV):','Position',[x4e y4e 150 22]);
edEmax = uieditfield(t4,'numeric','Value',200,'Position',[x4e+150 y4e 120 22]);

y4e = y4e-d4e;
uilabel(t4,'Text','Select Spectrum:','Position',[x4e y4e 150 22]);
ddSpec = uidropdown(t4,'Items',{'Both','Energy Corrected only','No Energy Correction only'}, ...
    'Value','Both','Position',[x4e+150 y4e 200 22]);

y4e = y4e-d4e;
uibutton(t4,'Text','Plot Spectra','Position',[x4e y4e 220 28], ...
    'ButtonPushedFcn',@(~,~)plotSpectra());

y4e = y4e-d4e+6;
uilabel(t4,'Text','Smoother:','Position',[x4e y4e 80 22]);
ddFWHM = uidropdown(t4,'Items',{'moving','loess','lowess','sgolay','filtfilt'}, ...
    'Value','loess','Position',[x4e+80 y4e 100 22]);
uilabel(t4,'Text','Span:','Position',[x4e+190 y4e 40 22]);
edFspan = uieditfield(t4,'numeric','Value',0.02,'Position',[x4e+232 y4e 80 22]);

y4e = y4e-d4e;
uibutton(t4,'Text','Apply Smoothing and Calculate FWHM', ...
    'Position',[x4e y4e 260 28],'ButtonPushedFcn',@(~,~)calcFWHM());

% Save spectra (left column, no overlap)
y4e = y4e - d4e;
uilabel(t4,'Text','Spectra File Prefix:','Position',[x4e y4e 150 22]);
edSP = uieditfield(t4,'text','Value','spectra','Position',[x4e+150 y4e 180 22]);

% Save button
y4e = y4e - 34;
uibutton(t4,'Text','Save Spectra (NoE & E)','Position',[x4e y4e 220 28], ...
    'ButtonPushedFcn',@(~,~)saveSpectra());

% Save status
y4e = y4e - 40;
lblSpecSave = uilabel(t4,'Text','', ...
    'Position',[x4e y4e 360 40], 'WordWrap','on', 'FontColor',[0.05 0.5 0.05]);

% Export button
y4e = y4e - 56;
uibutton(t4,'Text','Export Image','Position',[x4e y4e 220 28], ...
    'ButtonPushedFcn',@(~,~)exportFWHM());

% Export status
y4e = y4e - 40;
lblExport3 = uilabel(t4,'Text','', ...
    'Position',[x4e y4e 360 40], 'WordWrap','on', 'FontColor',[0.05 0.5 0.05]);

% Curve-Fitter MAT status
y4e = y4e - 48;
lblCurve = uilabel(t4,'Text','', ...
    'Position',[x4e y4e 360 40], 'WordWrap','on', 'FontColor',[0.05 0.5 0.05]);

lblRes = uilabel(t4,'Text','','Position',[x4e 280 380 22],'FontColor',[0.1 0.1 0.6],'FontWeight','bold');
lblPT  = uilabel(t4,'Text','','Position',[x4e 230 380 22],'FontColor',[0.2 0.4 0.6],'FontWeight','bold');
lblEff = uilabel(t4,'Text','','Position',[x4e 180 380 22],'FontColor',[0.2 0.4 0.6],'FontWeight','bold');

axF   = uiaxes(t4,'Position',[440 180 800 470]);
title(axF, 'Calibration Energy Spectra'); xlabel(axF,'Energy (keV)'); ylabel(axF,'Counts'); grid(axF,'on');

txtF  = uitextarea(t4,'Editable','off','Position',[440 20 800 140], ...
    'Value',{'(FWHM Results)'});

%% ===================  TAB 5 : Calibration Plot ===================
axC1 = uiaxes(t5,'Position',[440 420 800 300]);
title(axC1,'Before Pixel Gain Correction Calibration Curve');
xlabel(axC1,'Energy (keV)'); ylabel(axC1,'Channel');

axC2 = uiaxes(t5,'Position',[440 50 800 300]);
title(axC2,'After Pixel Gain Correction Calibration Curve');
xlabel(axC2,'Energy (keV)'); ylabel(axC2,'Channel');

x5c=24; y5c=680;
uibutton(t5,'Text','Plot Calibration Curves','Position',[x5c y5c 220 28], ...
    'ButtonPushedFcn',@(~,~)plotCalibration());
y5c=y5c-40; uilabel(t5,'Text','File Prefix:','Position',[x5c y5c 90 22]);
edCP = uieditfield(t5,'text','Value','calib','Position',[x5c+90 y5c 150 22]);
y5c=y5c-34;
uibutton(t5,'Text','Export Calibration PNGs','Position',[x5c y5c 220 28], ...
    'ButtonPushedFcn',@(~,~)exportCalibrationPNG());
lblCalExp = uilabel(t5,'Text','','Position',[x5c+230 y5c 700 22],'FontColor',[0.05 0.5 0.05]);

txtEq = uitextarea(t5,'Editable','off','Position',[24 250 380 350], ...
    'Value',{'(Equations will appear here after you plot.)'});

%% ===================  TAB 6 : Neutron ===================
x6=24; y6=700;
uilabel(t6,'Text','Prefix (title & filename):','Position',[x6 y6 200 22]);
edNPrefix = uieditfield(t6,'text','Value','','Position',[x6+200 y6 200 22]);

y6=y6-40;
uibutton(t6,'Text','Plot Neutron Spectra','Position',[x6 y6 220 28], ...
    'ButtonPushedFcn',@(~,~)plotNeutron());
y6=y6-40; uilabel(t6,'Text','Smoother:','Position',[x6 y6 80 22]);
ddNS = uidropdown(t6,'Items',{'moving','loess','lowess','sgolay','filtfilt'}, ...
    'Value','loess','Position',[x6+80 y6 100 22]);
uilabel(t6,'Text','Span:','Position',[x6+190 y6 40 22]);
edNS = uieditfield(t6,'numeric','Value',0.02,'Position',[x6+232 y6 80 22], ...
    'ValueChangedFcn',@(~,~)updateNeutronRange());

y6=y6-44; uilabel(t6,'Text','Min Energy (keV):','Position',[x6 y6 120 22]);
edNEmin = uieditfield(t6,'numeric','Value',75,'Position',[x6+130 y6 80 22], ...
    'ValueChangedFcn',@(~,~)updateNeutronRange());
y6=y6-44; uilabel(t6,'Text','Max Energy (keV):','Position',[x6 y6 120 22]);
edNEmax = uieditfield(t6,'numeric','Value',200,'Position',[x6+130 y6 80 22], ...
    'ValueChangedFcn',@(~,~)updateNeutronRange());
modeChanged(); % set LEM/HEM defaults

% Save button
y6 = y6 - 44;
uibutton(t6,'Text','Save Processed Neutron Data','Position',[x6 y6 220 28], ...
    'ButtonPushedFcn',@(~,~)saveNeutron());

% Status
y6 = y6 - 36;
lblNeuSave = uilabel(t6,'Text','', ...
    'Position',[x6 y6 360 36], 'WordWrap','on', 'FontColor',[0.05 0.5 0.05]);

axN = uiaxes(t6,'Position',[440 80 800 600]);
title(axN,'Neutron Spectra');
xlabel(axN,'Energy (keV)'); ylabel(axN,'Counts'); grid(axN,'on');

%% =================== Callbacks ===================
    function modeChanged()
        S = getappdata(fig,'S');
        S.energyMode = ddMode.Value; setappdata(fig,'S',S);
        if strcmp(ddMode.Value,'LEM')
            edNEmin.Value = 75;  edNEmax.Value = 200;
        else
            edNEmin.Value = 140; edNEmax.Value = 350;
        end
        updateDefaultsForIsoMode();
        updateNeutronRange();
    end

    function isoChanged()
        S = getappdata(fig,'S'); S.iso = ddIso.Value; setappdata(fig,'S',S);
        updateDefaultsForIsoMode();
    end

    function updateDefaultsForIsoMode()
        iso  = ddIso.Value;
        mode = ddMode.Value;
        isEu152HEM = strcmp(iso,'Eu-152') && strcmp(mode,'HEM');

        % Uncorrected spectra tab → Plot 2 range
        if strcmp(iso,'Am-241')
            edP2min.Value = 150; edP2max.Value = 700;
        elseif isEu152HEM
            edP2min.Value = 400; edP2max.Value = 1100;
        elseif strcmp(iso,'Eu-152') && strcmp(mode,'LEM')
            edP2min.Value = 200; edP2max.Value = 1000;
        else
            edP2min.Value = 200; edP2max.Value = 1000;
        end

        % Uncorrected spectra tab → Quick Energy range
        if isEu152HEM
            edQemin.Value = 150; edQemax.Value = 500;
        else
            if edQemin.Value<=0, edQemin.Value=40; end
            if edQemax.Value<=edQemin.Value, edQemax.Value=200; end
        end

        % Pixel gain correction defaults
        switch iso
            case 'Am-241'
                edE1obs.Value = 59.6;   edE1tar.Value = 59.6;
                edE2obs.Value = 0;      edE2tar.Value = 0;
                edE2obs.Enable = 'off'; edE2tar.Enable = 'off';
            case 'Eu-152'
                if strcmp(mode,'HEM')
                    edE1obs.Value = 245;  edE2obs.Value = 344;
                    edE1tar.Value = 245;  edE2tar.Value = 344;
                    edE2obs.Enable = 'on'; edE2tar.Enable = 'on';
                else
                    edE1obs.Value = 121.8; edE1tar.Value = 121.8;
                    edE2obs.Value = 0;     edE2tar.Value = 0;
                    edE2obs.Enable = 'off'; edE2tar.Enable = 'off';
                end
            otherwise % Co-57
                edE1obs.Value = 120.4; edE2obs.Value = 136.24;
                edE1tar.Value = 122;   edE2tar.Value = 136;
                edE2obs.Enable = 'on'; edE2tar.Enable = 'on';
        end

        % Energy Correction tab defaults (Eu-152 HEM)
        if isEu152HEM
            edEmin.Value = 180; edEmax.Value = 450;
        end

        % If quick calibration exists, keep Plot 3 view in sync
        try, plotQuickE1D(false); catch, end
    end

    function toggleBG2()
        if cbBG2.Value, btnBG2.Enable='on'; else, btnBG2.Enable='off'; end
    end

    function loadBG1()
        S = getappdata(fig,'S');
        [f,p] = uigetfile(fullfile(S.path,'*.mat'),'Select Background 1');
        if isequal(f,0), return; end
        tmp = load(fullfile(p,f)); S.bg1 = tmp; S.path = p;
        setappdata(fig,'S',S);
        lblBG1.Text = sprintf('Loaded: %s',f);
    end

    function loadBG2()
        S = getappdata(fig,'S'); if ~isfield(S,'path'), S.path=pwd; end
        [f,p] = uigetfile(fullfile(S.path,'*.mat'),'Select Background 2');
        if isequal(f,0), return; end
        tmp = load(fullfile(p,f)); S.bg2 = tmp; S.path = p;
        setappdata(fig,'S',S);
        lblBG2.Text = sprintf('Loaded: %s',f);
    end

    function loadCal()
        S = getappdata(fig,'S'); if ~isfield(S,'path'), S.path=pwd; end
        [f,p] = uigetfile(fullfile(S.path,'*.mat'),'Select Calibration Source');
        if isequal(f,0), return; end
        tmp = load(fullfile(p,f));
        S.cal = tmp; S.path = p; S.energyMode = ddMode.Value; S.iso = ddIso.Value;
        setappdata(fig,'S',S);
        lblCal.Text = sprintf('Loaded: %s',f);
        updateDefaultsForIsoMode();
    end

    function loadNeutron()
        S = getappdata(fig,'S'); if ~isfield(S,'path'), S.path=pwd; end
        [f,p] = uigetfile(fullfile(S.path,'*.mat'),'Select Neutron Exposure');
        if isequal(f,0), return; end
        tmp = load(fullfile(p,f));
        S.neutron = tmp; S.path = p;
        setappdata(fig,'S',S);
        lblNeu.Text = sprintf('Loaded: %s',f);
    end

    function plotBGvCal(applySmooth)
        if nargin<1, applySmooth=false; end
        S = getappdata(fig,'S');
        if ~isfield(S,'bg1') || ~isfield(S,'cal'), return; end
        try
            bg = S.bg1.LMmap_noEcorrect;
            if cbBG2.Value && isfield(S,'bg2'), bg = (bg + S.bg2.LMmap_noEcorrect)/2; end
            cal = S.cal.LMmap_noEcorrect;
            assert(isequal(size(bg),size(cal)),'BG and Cal sizes differ.');

            x1 = max(1,round(edP1min.Value)); x2 = min(size(cal,2),round(edP1max.Value));
            rng = x1:x2;
            yBG = sum(bg(:,rng),1); yCal = sum(cal(:,rng),1);

            if applySmooth
                yBG  = smoothVector(yBG, ddS1.Value, edS1.Value);
                yCal = smoothVector(yCal, ddS1.Value, edS1.Value);
            end
            yBG(yBG<0)=0; yCal(yCal<0)=0;

            cla(axBG1);
            plot(axBG1, rng, yBG,'b', rng, yCal,'r','LineWidth',1.4);
            legend(axBG1,{'Background','Calibration Source'});
            grid(axBG1,'on');
        catch ME
            uialert(fig,ME.message,'Plot 1 error');
        end
    end

    function plotCorrected1D(applySmooth)
        if nargin<1, applySmooth=false; end
        S = getappdata(fig,'S');
        if ~isfield(S,'bg1') || ~isfield(S,'cal'), return; end
        try
            bg = S.bg1.LMmap_noEcorrect;
            if cbBG2.Value && isfield(S,'bg2'), bg = (bg + S.bg2.LMmap_noEcorrect)/2; end
            cal = S.cal.LMmap_noEcorrect;
            assert(isequal(size(bg),size(cal)),'BG and Cal sizes differ.');
            corr = cal - bg;
            S.corrected = corr; setappdata(fig,'S',S);

            x1 = max(1,round(edP2min.Value)); x2 = min(size(corr,2),round(edP2max.Value));
            rng = x1:x2; y = sum(corr(:,rng),1);

            if applySmooth
                y = smoothVector(y, ddS2.Value, edS2.Value);
            end
            y(y<0)=0;

            cla(axBG2);
            plot(axBG2, rng, y, 'Color',S.COLORS.noE,'LineWidth',1.4);
            legend(axBG2,{'No Energy Correction'}); grid(axBG2,'on');

            % ----- QUICK two-peak or single-peak -----
            iso  = ddIso.Value;
            mode = ddMode.Value;
            isEu152HEM = strcmp(iso,'Eu-152') && strcmp(mode,'HEM');
            isCo57     = strcmp(iso,'Co-57');

            if applySmooth && (isEu152HEM || isCo57)
                if isEu152HEM
                    roi1 = [500 600]; E1 = 245;
                    roi2 = [800 900]; E2 = 344;
                else
                    roi1 = [600 700]; E1 = 122;
                    roi2 = [720 820]; E2 = 136;
                end

                rr1 = [max(roi1(1),rng(1)) min(roi1(2),rng(end))];
                if rr1(2)<=rr1(1), rr1 = roi1; end
                seg1 = sum(corr(:,rr1(1):rr1(2)),1);
                seg1 = smoothVector(seg1, ddS2.Value, edS2.Value);
                [~,i1] = max(seg1); ch1 = rr1(1)+i1-1;

                rr2 = [max(roi2(1),rng(1)) min(roi2(2),rng(end))];
                if rr2(2)<=rr2(1), rr2 = roi2; end
                seg2 = sum(corr(:,rr2(1):rr2(2)),1);
                seg2 = smoothVector(seg2, ddS2.Value, edS2.Value);
                [~,i2] = max(seg2); ch2 = rr2(1)+i2-1;

                s1 = E1 / ch1; s2 = E2 / ch2;
                m2 = (E2 - E1) / (ch2 - ch1);
                b2 = E1 - m2*ch1;

                C = size(S.corrected,2);
                S.calQuick = struct( ...
                    'type','two-peak', ...
                    'chPeaks',[ch1 ch2], ...
                    'energies',[E1 E2], ...
                    'slopes',[s1 s2], ...
                    'two_point',struct('slope',m2,'offset',b2) );
                if isempty(S.calFinal)
                    S.energyCalibration = struct('avgChannel',mean([ch1 ch2]),'slope',m2,'offset',b2);
                    S.keV = (0:C-1)*m2 + b2;
                end
                setappdata(fig,'S',S);

                lblQpk.Text    = sprintf('Quick peaks: ch1=%.1f (%.1f keV), ch2=%.1f (%.1f keV)', ch1,E1,ch2,E2);
                lblQslope.Text = sprintf('Per-peak slopes: s1=%.6f, s2=%.6f keV/ch', s1, s2);
                lblQoff.Text   = sprintf('Two-pt quick offset b=%.3f keV', b2);
                lblQ2pt.Text   = sprintf('Two-pt quick slope m=%.6f keV/ch', m2);

            elseif applySmooth
                % Single-peak quick
                rois = isotopeROIs(iso,mode);
                r = rois(1,:); r(1)=max(1,r(1)); r(2)=min(size(corr,2),r(2));
                rr = [max(r(1),rng(1)) min(r(2),rng(end))];
                if rr(2)<=rr(1), rr = r; end
                seg = sum(corr(:,rr(1):rr(2)),1);
                seg = smoothVector(seg, ddS2.Value, edS2.Value);
                [~,ii] = max(seg);
                chpk = rr(1)+ii-1;

                switch iso
                    case 'Am-241', Eref = 59.6;
                    case 'Eu-152', Eref = 121.8;
                    otherwise,     Eref = 122;
                end
                slopeQ  = Eref / chpk;
                offsetQ = edQOff.Value;

                C = size(S.corrected,2);
                S.calQuick = struct('type','single','slope',slopeQ,'offset',offsetQ,'chPeak',chpk);
                if isempty(S.calFinal)
                    S.energyCalibration = struct('avgChannel',chpk,'slope',slopeQ,'offset',offsetQ);
                    S.keV = (0:C-1)*slopeQ + offsetQ;
                end
                setappdata(fig,'S',S);

                lblQpk.Text    = sprintf('Quick peak channel = %.2f (smoothed, ROI)', chpk);
                lblQslope.Text = sprintf('Quick slope = %.6f keV/ch', slopeQ);
                lblQoff.Text   = sprintf('Quick offset = %.3f keV', offsetQ);
                lblQ2pt.Text   = '';
            end
        catch ME
            uialert(fig,ME.message,'Plot 2 error');
        end
    end

    function quickOffsetChanged()
        S = getappdata(fig,'S');
        if isempty(S.calQuick), return; end
        if ~isfield(S.calQuick,'two_point')
            S.calQuick.offset = edQOff.Value;
            if isempty(S.calFinal) && isfield(S,'corrected')
                C = size(S.corrected,2);
                S.energyCalibration = struct('avgChannel',S.calQuick.chPeak, ...
                                             'slope',S.calQuick.slope,'offset',S.calQuick.offset);
                S.keV = (0:C-1)*S.calQuick.slope + S.calQuick.offset;
            end
            setappdata(fig,'S',S);
            lblQoff.Text = sprintf('Quick offset = %.3f keV', edQOff.Value);
            refreshViewsAfterCalibration();
        end
    end

    function plotQuickE1D(applySmooth)
        if nargin<1, applySmooth=false; end
        S = getappdata(fig,'S');
        if ~isfield(S,'corrected') || isempty(S.calQuick), return; end
        y = sum(S.corrected,1); y(y<0)=0;
        if applySmooth
            y = smoothVector(y, ddS3.Value, edS3.Value); y(y<0)=0;
        end
        if isfield(S.calQuick,'two_point')
            m = S.calQuick.two_point.slope; b = S.calQuick.two_point.offset;
        else
            m = S.calQuick.slope; b = S.calQuick.offset;
        end
        keV = (0:numel(y)-1)*m + b;
        mask = keV>=edQemin.Value & keV<=edQemax.Value;

        cla(axQuickE);
        plot(axQuickE, keV(mask), y(mask), 'Color', S.COLORS.E, 'LineWidth',1.4);
        legend(axQuickE,{'Energy Corrected'});
        title(axQuickE, sprintf('Quick Energy-Calibrated 1D (before gain correction) — %s', ddIso.Value));
        xlabel(axQuickE,'Energy (keV)'); ylabel(axQuickE,'Counts'); grid(axQuickE,'on');
        xlim(axQuickE,[edQemin.Value edQemax.Value]);
        if any(mask), ylim(axQuickE,[0 1.05*max(y(mask))]); end

        refreshViewsAfterCalibration();
    end

    function plot2D()
        S = getappdata(fig,'S');
        if ~isfield(S,'corrected'), return; end
        M = S.corrected;
        R = min(1024,size(M,1)); C = min(4096,size(M,2));
        x1 = max(1,round(edP3min.Value)); x2 = min(C,round(edP3max.Value));
        rng = x1:x2;
        cla(axBG3);
        imagesc(axBG3, rng, 1:R, M(1:R,rng)); colormap(axBG3,'jet');
        set(axBG3,'YDir','normal'); xlim(axBG3,[rng(1) rng(end)]); ylim(axBG3,[1 R]);
        xlabel(axBG3,'Channel'); ylabel(axBG3,'Pixels'); grid(axBG3,'on');

        if cbMark.Value
            hold(axBG3,'on');
            iso  = ddIso.Value; mode = ddMode.Value;
            rois = isotopeROIs(iso,mode);
            for k=1:size(rois,1)
                r0 = [max(rng(1),rois(k,1)) min(rng(end),rois(k,2))];
                if r0(2)<=r0(1), continue; end
                seg = M(1:R, r0(1):r0(2));
                [~,idx] = max(seg,[],2);
                ch = idx + r0(1) - 1; row = (1:R)';
                plot(axBG3,ch,row,'ko','MarkerFaceColor','y','MarkerSize',3);
            end
            hold(axBG3,'off');
        end
    end

    function computeCalibrationAfterGainCorrection()
        S = getappdata(fig,'S');
        if ~isfield(S,'corrected')
            lblAvg.Text='Run BG-correction first.'; return;
        end
        M = S.corrected;
        R = min(1024,size(M,1));
        iso  = ddIso.Value; mode = ddMode.Value;
        isEu152HEM = strcmp(iso,'Eu-152') && strcmp(mode,'HEM');

        if isEu152HEM
            roi1=[500 600];  e1=245;
            roi2=[800 900];  e2=344;
            [~,i1] = max(M(1:R,roi1(1):roi1(2)),[],2); ch1 = mean(i1 + roi1(1) - 1);
            [~,i2] = max(M(1:R,roi2(1):roi2(2)),[],2); ch2 = mean(i2 + roi2(1) - 1);
            slope  = (e2-e1)/(ch2-ch1);
            offset = e1 - slope*ch1;
            lblAvg.Text = sprintf('Avg Max Channels (after pixel gain correction): ch1=%.2f (245 keV), ch2=%.2f (344 keV)',ch1,ch2);
        elseif strcmp(iso,'Co-57')
            roi1=[600 700]; e1=122;
            roi2=[720 820]; e2=136;
            [~,i1]=max(M(1:R,roi1(1):roi1(2)),[],2); ch1=mean(i1 + roi1(1) - 1);
            [~,i2]=max(M(1:R,roi2(1):roi2(2)),[],2); ch2=mean(i2 + roi2(1) - 1);
            slope  = (e2-e1)/(ch2-ch1);
            offset = e1 - slope*ch1;
            lblAvg.Text = sprintf('Avg Max Channels (after pixel gain correction): ch1=%.2f (122 keV), ch2=%.2f (136 keV)',ch1,ch2);
        else
            rois = isotopeROIs(iso,mode);
            r = rois(1,:); r(1)=max(1,r(1)); r(2)=min(size(M,2),r(2));
            [~,i] = max(M(1:R,r(1):r(2)),[],2); ch = mean(i + r(1) - 1);
            switch iso
                case 'Am-241', energy_ref=59.6;
                case 'Eu-152', energy_ref = 121.8;
                otherwise,     energy_ref=122;
            end
            slope  = energy_ref / ch;
            offset = 0;
            lblAvg.Text = sprintf('Avg Max Channel (after pixel gain correction) = %.2f',ch);
        end

        C = size(M,2);
        S.calFinal = struct('slope',slope,'offset',offset);
        S.energyCalibration = struct('avgChannel',NaN,'slope',slope,'offset',offset);
        S.keV = (0:C-1)*slope + offset;
        setappdata(fig,'S',S);

        edM0.Value = slope; edB0.Value = offset;
        refreshViewsAfterCalibration();
    end

    function solveAndApply()
        lblSolveOut1.Text=''; lblSolveOut2.Text=''; lblSolveWarn.Text='';
        m0 = edM0.Value; b0 = edB0.Value;
        E1o = edE1obs.Value; E2o = edE2obs.Value;
        E1t = edE1tar.Value; E2t = edE2tar.Value;
        if ~isfinite(m0) || m0==0 || ~isfinite(b0) || ~isfinite(E1o) || ~isfinite(E2o) || ~isfinite(E1t) || ~isfinite(E2t)
            lblSolveWarn.Text='Provide valid numeric values (m0 non-zero).'; return;
        end
        ch1 = (E1o - b0)/m0;  ch2 = (E2o - b0)/m0;
        if ~isfinite(ch1) || ~isfinite(ch2) || abs(ch2-ch1)<eps
            lblSolveWarn.Text='Invalid channels from current mapping.'; return;
        end
        m = (E2t - E1t)/(ch2 - ch1);
        b = E1t - m*ch1;
        lblSolveOut1.Text = sprintf('Computed slope = %.6f keV/ch', m);
        lblSolveOut2.Text = sprintf('Computed offset = %.6f keV', b);

        S = getappdata(fig,'S');
        if ~isfield(S,'corrected'), lblSolveWarn.Text='Run BG-correction first.'; return; end
        C = size(S.corrected,2);
        S.calFinal = struct('slope',m,'offset',b);
        S.energyCalibration = struct('avgChannel',NaN,'slope',m,'offset',b);
        S.keV = (0:C-1)*m + b;
        setappdata(fig,'S',S);
        refreshViewsAfterCalibration();
    end

    % Manual apply when slope/offset fields change
    function applyManualMB()
        m = edM0.Value; b = edB0.Value;
        if ~isfinite(m) || m==0 || ~isfinite(b), return; end
        S = getappdata(fig,'S');
        if ~isfield(S,'corrected'), return; end
        C = size(S.corrected,2);
        S.calFinal = struct('slope',m,'offset',b);
        S.energyCalibration = struct('avgChannel',NaN,'slope',m,'offset',b);
        S.keV = (0:C-1)*m + b;
        setappdata(fig,'S',S);
        refreshViewsAfterCalibration();
    end

    function refreshViewsAfterCalibration()
        S = getappdata(fig,'S');
        if isfield(S,'corrected')
            C = size(S.corrected,2);
            S.keV = (0:C-1)*S.energyCalibration.slope + S.energyCalibration.offset;
            setappdata(fig,'S',S);
        end

        % Tab 4 spectra
        if isvalid(axF) && isfield(S,'corrected_E') && isfield(S,'corrected_noE')
            yE = sum(S.corrected_E,1);
            yN = sum(S.corrected_noE,1);
            keV = (0:numel(yE)-1)*S.energyCalibration.slope + S.energyCalibration.offset;
            mask = keV>=edEmin.Value & keV<=edEmax.Value;
            cla(axF); hold(axF,'on');
            plot(axF,keV(mask),yE(mask),'Color',S.COLORS.E,'LineWidth',1.5);
            plot(axF,keV(mask),yN(mask),'Color',S.COLORS.noE,'LineWidth',1.5);
            legend(axF,{'Energy Corrected','No Energy Correction'});
            title(axF, sprintf('%s Calibration Energy Spectra', ddIso.Value));
            grid(axF,'on'); hold(axF,'off');
        end

        % Neutron tab
        updateNeutronRange();
    end

    % =================== SAVES / EXPORTS ===================
    function saveBGCorr()
        S = getappdata(fig,'S'); lblSave.Text = '';
        if ~isfield(S,'corrected')
            lblSave.Text='Nothing to save.'; lblSave.FontColor=[.8 .1 .1]; return;
        end
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        try
            fP = fullfile(S.path,[edPrefix.Value '_BGcorr.mat']);
            save(fP,'S');
            lblSave.Text=sprintf('BG-corrected data saved: %s', fP); lblSave.FontColor=[.1 .5 .1];
        catch ME
            lblSave.Text=['Save error: ' ME.message]; lblSave.FontColor=[.8 .1 .1];
        end
    end

    function exportTab2()
        S = getappdata(fig,'S'); lblExport2.Text='';
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        try
            f1 = fullfile(S.path,[edPrefix.Value '_BGvsCal.png']);
            f2 = fullfile(S.path,[edPrefix.Value '_Corrected1D_NoE.png']);
            f3 = fullfile(S.path,[edPrefix.Value '_QuickEnergy1D.png']);
            exportgraphics(axBG1,   f1);
            exportgraphics(axBG2,   f2);
            exportgraphics(axQuickE,f3);
            lblExport2.Text=sprintf('Images exported to folder: %s', S.path); lblExport2.FontColor=[.1 .5 .1];
        catch ME
            lblExport2.Text=['Export failed: ' ME.message]; lblExport2.FontColor=[.8 .1 .1];
        end
    end

    function saveSpectra()
        S = getappdata(fig,'S'); lblSpecSave.Text='';
        if ~isfield(S,'bg1') || ~isfield(S,'cal') || ~isfield(S,'energyCalibration')
            lblSpecSave.Text='Plot spectra first.'; lblSpecSave.FontColor=[.8 .1 .1]; return; end
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        try
            [corrE, corrN] = getCorrectedEN();
            yE = sum(corrE,1);
            yN = sum(corrN,1);
            m=S.energyCalibration.slope; b=S.energyCalibration.offset;
            energy_keV = (0:numel(yE)-1)*m + b;
            s = struct('spectrum_E', yE, 'spectrum_noE', yN, 'energy_keV', energy_keV);
            fP = fullfile(S.path,[edSP.Value '_spectra.mat']);
            save(fP, '-struct', 's');
            lblSpecSave.Text=sprintf('Spectra saved: %s', fP); lblSpecSave.FontColor=[.1 .5 .1];
        catch ME
            lblSpecSave.Text=['Save error: ' ME.message]; lblSpecSave.FontColor=[.8 .1 .1];
        end
    end

    function exportFWHM()
        S = getappdata(fig,'S'); lblExport3.Text='';
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        try
            fP = fullfile(S.path,[edSP.Value '_FWHM.png']);
            exportgraphics(axF, fP);
            lblExport3.Text=sprintf('FWHM image exported: %s', fP); lblExport3.FontColor=[.1 .5 .1];
        catch ME
            lblExport3.Text=['Export failed: ' ME.message]; lblExport3.FontColor=[.8 .1 .1];
        end
    end

    function plotSpectra()
        S = getappdata(fig,'S');
        if ~isfield(S,'bg1') || ~isfield(S,'cal') || ~isfield(S,'energyCalibration')
            uialert(fig,'Load BG+Cal and compute/refresh calibration first.','Missing data'); return;
        end
        [corrE, corrN] = getCorrectedEN();
        yE = sum(corrE,1); yN = sum(corrN,1);
        keV = (0:numel(yE)-1)*S.energyCalibration.slope + S.energyCalibration.offset;
        mask = keV>=edEmin.Value & keV<=edEmax.Value;
        cla(axF);
        switch ddSpec.Value
            case 'Both'
                plot(axF,keV(mask),yE(mask),'Color',S.COLORS.E,'LineWidth',1.5); hold(axF,'on');
                plot(axF,keV(mask),yN(mask),'Color',S.COLORS.noE,'LineWidth',1.5); hold(axF,'off');
                legend(axF,{'Energy Corrected','No Energy Correction'});
            case 'Energy Corrected only'
                plot(axF,keV(mask),yE(mask),'Color',S.COLORS.E,'LineWidth',1.5); legend(axF,{'Energy Corrected'});
            otherwise
                plot(axF,keV(mask),yN(mask),'Color',S.COLORS.noE,'LineWidth',1.5); legend(axF,{'No Energy Correction'});
        end
        title(axF, sprintf('%s Calibration Energy Spectra', ddIso.Value));
        grid(axF,'on');
        S.corrected_E = corrE; S.corrected_noE = corrN; setappdata(fig,'S',S);
    end

    function [E,N] = getCorrectedEN()
        S = getappdata(fig,'S');
        [BG_E, BG_N] = getBackgroundMaps(S);
        E = S.cal.LMmap_Ecorrect   - BG_E;
        N = S.cal.LMmap_noEcorrect - BG_N;
        assert(isequal(size(E),size(N)),'E and NoE sizes differ.');
    end

    function [BG_E, BG_N] = getBackgroundMaps(S)
        BG_E = S.bg1.LMmap_Ecorrect;
        BG_N = S.bg1.LMmap_noEcorrect;
        assert(isequal(size(BG_E),size(BG_N)), 'BG1 Ecorrect and noEcorrect sizes differ.');
        if cbBG2.Value && isfield(S,'bg2')
            assert(isequal(size(BG_E),size(S.bg2.LMmap_Ecorrect)), 'BG1 and BG2 Ecorrect sizes differ.');
            assert(isequal(size(BG_N),size(S.bg2.LMmap_noEcorrect)), 'BG1 and BG2 noEcorrect sizes differ.');
            BG_E = (BG_E + S.bg2.LMmap_Ecorrect)/2;
            BG_N = (BG_N + S.bg2.LMmap_noEcorrect)/2;
        end
    end

    function [fwhm, K, ok] = fwhmRobust(keV,y,roi)
        ok=false; fwhm=NaN; K=struct('kPk',[],'yPk',[],'yHalf',[],'hL',[],'hR',[]);
        idx = builtin('find', keV>=roi(1) & keV<=roi(2));
        if numel(idx)<5, return; end
        [yPk,r] = max(y(idx)); iPk = idx(1)+r-1; kPk = keV(iPk); K.kPk=kPk; K.yPk=yPk;
        W = 15;
        idS = builtin('find', keV>=kPk-W & keV<=kPk+W);
        if numel(idS)<5, return; end
        yS = y(idS); kS=keV(idS); jPk=builtin('find', idS==iPk, 1);
        L=max(1,round(0.1*numel(yS)));
        base = 0.5*(median(yS(1:L))+median(yS(end-L+1:end)));
        yHalf = base + 0.5*(yPk-base); K.yHalf=yHalf;
        iL = builtin('find', yS(1:jPk) <= yHalf, 1, 'last');
        iR = jPk-1 + builtin('find', yS(jPk:end) <= yHalf, 1, 'first');
        if isempty(iL) || isempty(iR)
            W2=25; idS = builtin('find', keV>=kPk-W2 & keV<=kPk+W2);
            yS=y(idS); kS=keV(idS); jPk=builtin('find', idS==iPk, 1);
            if numel(yS)<5, return; end
            L=max(1,round(0.1*numel(yS)));
            base = 0.5*(median(yS(1:L))+median(yS(end-L+1:end)));
            yHalf = base + 0.5*(yPk-base); K.yHalf=yHalf;
            iL = builtin('find', yS(1:jPk) <= yHalf, 1, 'last');
            iR = jPk-1 + builtin('find', yS(jPk:end) <= yHalf, 1, 'first');
            if isempty(iL) || isempty(iR), return; end
        end
        kL = interp1([yS(iL) yS(iL+1)],[kS(iL) kS(iL+1)],yHalf,'linear','extrap');
        kR = interp1([yS(iR-1) yS(iR)],[kS(iR-1) kS(iR)],yHalf,'linear','extrap');
        f = kR-kL; if ~isfinite(f) || f<=0, return; end
        fwhm=f; K.hL=kL; K.hR=kR; ok=true;
    end

    function calcFWHM()
    S = getappdata(fig,'S');

    if ~(isfield(S,'corrected_E') && isfield(S,'corrected_noE'))
        try
            [corrE, corrN] = getCorrectedEN();
            S.corrected_E   = corrE;
            S.corrected_noE = corrN;
            setappdata(fig,'S',S);
        catch
            uialert(fig,'Plot spectra first (Tab 4 → Plot Spectra).','Info');
            return;
        end
    end

    yE = sum(S.corrected_E,1); 
    yN = sum(S.corrected_noE,1);
    yE = smoothVector(yE, ddFWHM.Value, edFspan.Value);
    yN = smoothVector(yN, ddFWHM.Value, edFspan.Value);
    yE(yE<0)=0; yN(yN<0)=0;

    keV = (0:numel(yE)-1)*S.energyCalibration.slope + S.energyCalibration.offset;

    iso  = ddIso.Value;
    mode = ddMode.Value;
    roisE = chooseIsotopeROIsEnergy(iso,mode,[edEmin.Value edEmax.Value]);

    cla(axF); hold(axF,'on');
    mask = keV>=edEmin.Value & keV<=edEmax.Value;
    plot(axF,keV(mask),yE(mask),'Color',S.COLORS.E,'LineWidth',1.5);
    plot(axF,keV(mask),yN(mask),'Color',S.COLORS.noE,'LineWidth',1.5);
    legend(axF,{'Energy Corrected','No Energy Correction'});
    title(axF, sprintf('%s Calibration Energy Spectra', iso));
    grid(axF,'on');

    out = {};
    for r = 1:size(roisE,1)
        roi = roisE(r,:);

        [fE,KE,okE] = fwhmRobust(keV,yE,roi);
        if okE
            plot(axF,[KE.hL KE.hR],[KE.yHalf KE.yHalf],'o', ...
                 'LineStyle','none','MarkerFaceColor',S.COLORS.E,'MarkerEdgeColor',S.COLORS.E);
            out{end+1} = sprintf('FWHM (Energy-Corrected) @ %.1f keV: %.2f keV (%.2f%%)', ...
                                 KE.kPk, fE, 100*fE/KE.kPk);
        else
            out{end+1} = sprintf('FWHM (Energy-Corrected) @ ~%.1f keV: n/a', mean(roi));
        end

        [fN,KN,okN] = fwhmRobust(keV,yN,roi);
        if okN
            plot(axF,[KN.hL KN.hR],[KN.yHalf KN.yHalf],'s', ...
                 'LineStyle','none','MarkerFaceColor',S.COLORS.noE,'MarkerEdgeColor',S.COLORS.noE);
            out{end+1} = sprintf('FWHM (No-Energy-Correction) @ %.1f keV: %.2f keV (%.2f%%)', ...
                                 KN.kPk, fN, 100*fN/KN.kPk);
        else
            out{end+1} = sprintf('FWHM (No-Energy-Correction) @ ~%.1f keV: n/a', mean(roi));
        end
    end
    hold(axF,'off');

    if isempty(out), out = {'(FWHM not found in current range)'}; end
    txtF.Value = out;

    try
        x = keV(mask);
        saveCurveFitMATs(S.path, edSP.Value, x, yE(mask), yN(mask));
        lblCurve.Text = sprintf('Curve Fitter MAT files saved in: %s', S.path);
        lblCurve.FontColor = [0.1 0.5 0.1];
    catch ME
        lblCurve.Text = ['Curve Fitter save failed: ' ME.message];
        lblCurve.FontColor = [0.8 0.1 0.1];
    end
end

    function plotCalibration()
        S = getappdata(fig,'S');
        iso  = ddIso.Value;
        mode = ddMode.Value;
        knownE = pickKnownEnergies(iso,mode);   % vector of energies

        % Quick mapping
        cla(axC1);
        if ~isempty(S.calQuick)
            if isfield(S.calQuick,'two_point')
                m = S.calQuick.two_point.slope;
                b = S.calQuick.two_point.offset;
            else
                m = S.calQuick.slope;
                b = S.calQuick.offset;
            end
            Egrid = linspace(max(min(knownE)-40,1), max(knownE)+40, 200);
            chQuick = (Egrid - b) / m;
            plot(axC1, Egrid, chQuick, 'k-', 'LineWidth',2); hold(axC1,'on');
            for k=1:numel(knownE)
                plot(axC1, knownE(k), (knownE(k)-b)/m, 'ro','MarkerSize',8,'LineWidth',2);
            end
            legend(axC1,{'Quick mapping','Reference energies'},'Location','northwest');
            title(axC1,'Before Pixel Gain Correction Calibration Curve');
            hold(axC1,'off');
        else
            text(axC1,0.1,0.5,'Quick mapping not computed yet (Tab 2).','Units','normalized');
        end
        xlabel(axC1,'Energy (keV)'); ylabel(axC1,'Channel'); grid(axC1,'on');

        % Final mapping
        cla(axC2);
        if ~isempty(S.calFinal)
            mf = S.calFinal.slope;
            bf = S.calFinal.offset;
            Egrid = linspace(max(min(knownE)-40,1), max(knownE)+40, 200);
            chFinal = (Egrid - bf) / mf;
            plot(axC2, Egrid, chFinal, 'k--', 'LineWidth',2); hold(axC2,'on');
            for k=1:numel(knownE)
                plot(axC2, knownE(k), (knownE(k)-bf)/mf, 'ro','MarkerSize',8,'LineWidth',2);
            end
            legend(axC2,{'Final mapping','Reference energies'},'Location','northwest');
            title(axC2,'After Pixel Gain Correction Calibration Curve');
            hold(axC2,'off');
        else
            text(axC2,0.1,0.5,'Final mapping not computed yet (Tab 3 solver).','Units','normalized');
        end
        xlabel(axC2,'Energy (keV)'); ylabel(axC2,'Channel'); grid(axC2,'on');

        % Equations box
        lines = {};
        if ~isempty(S.calQuick)
            if isfield(S.calQuick,'two_point')
                mq=S.calQuick.two_point.slope; bq=S.calQuick.two_point.offset;
            else
                mq=S.calQuick.slope;          bq=S.calQuick.offset;
            end
            aq=1/mq; cq=-bq/mq;
            [sq,bqabs] = signedStr(bq); [scq,cqabs] = signedStr(cq);
            lines{end+1}='Quick mapping (from Tab 2):';
            lines{end+1}=sprintf('  E(ch)  = %.6f * ch %s %.3f', mq, sq, bqabs);
            lines{end+1}=sprintf('  ch(E)  = %.6f * E  %s %.6f', aq, scq, cqabs);
            lines{end+1}='';
        end
        if ~isempty(S.calFinal)
            mf=S.calFinal.slope; bf=S.calFinal.offset; af=1/mf; cf=-bf/mf;
            [sf,bfabs] = signedStr(bf); [scf,cfabs] = signedStr(cf);
            lines{end+1}='Final mapping (from Tab 3):';
            lines{end+1}=sprintf('  E(ch)  = %.6f * ch %s %.3f', mf, sf, bfabs);
            lines{end+1}=sprintf('  ch(E)  = %.6f * E  %s %.6f', af, scf, cfabs);
        end
        if isempty(lines), lines={'(No equations yet — compute Quick/Final first.)'}; end
        txtEq.Value = lines;
    end

    function exportCalibrationPNG()
        S = getappdata(fig,'S'); lblCalExp.Text='';
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        try
            fQ = fullfile(S.path, sprintf('%s_Calib_Quick.png', edCP.Value));
            fF = fullfile(S.path, sprintf('%s_Calib_Final.png', edCP.Value));
            exportgraphics(axC1, fQ);
            exportgraphics(axC2, fF);
            lblCalExp.Text=sprintf('Calibration images exported to: %s', S.path); lblCalExp.FontColor=[.1 .5 .1];
        catch ME
            lblCalExp.Text=['Export failed: ' ME.message]; lblCalExp.FontColor=[.8 .1 .1];
        end
    end

    function plotNeutron()
        S = getappdata(fig,'S');
        if ~isfield(S,'neutron') || ~isfield(S,'bg1')
            uialert(fig,'Load neutron and background first.','Missing'); return;
        end
        if isempty(S.calFinal)
            uialert(fig,'Apply Final calibration on Tab 3 first.','Missing'); return;
        end
        [BG_E, BG_N] = getBackgroundMaps(S);
        N_E = S.neutron.LMmap_Ecorrect   - BG_E;
        N_N = S.neutron.LMmap_noEcorrect - BG_N;

        mF = S.calFinal.slope; bF = S.calFinal.offset;
        keV = (0:size(N_E,2)-1)*mF + bF;
        S.neutron_processed_E = N_E; S.neutron_processed_noE = N_N; S.keV = keV;
        setappdata(fig,'S',S);

        updateNeutronRange();
    end

    function updateNeutronRange()
        S = getappdata(fig,'S');
        if ~isfield(S,'neutron_processed_E') || ~isfield(S,'neutron_processed_noE') ...
                || isempty(S.calFinal) || ~isvalid(axN)
            return;
        end
        yE = sum(S.neutron_processed_E,1);
        yN = sum(S.neutron_processed_noE,1);
        yE = smoothVector(yE, ddNS.Value, edNS.Value);
        yN = smoothVector(yN, ddNS.Value, edNS.Value);

        mF = S.calFinal.slope; bF = S.calFinal.offset;
        keV = (0:numel(yE)-1)*mF + bF;
        lo = edNEmin.Value; hi = edNEmax.Value;
        mask = keV>=lo & keV<=hi;

        cla(axN); hold(axN,'on');
        if any(mask)
            plot(axN,keV(mask),yE(mask),'Color',S.COLORS.E,'LineWidth',1.5);
            plot(axN,keV(mask),yN(mask),'Color',S.COLORS.noE,'LineWidth',1.5);
            ymax = max([yE(mask) yN(mask)],[],'all');
            if ~isempty(ymax) && isfinite(ymax) && ymax>0, ylim(axN,[0 1.05*ymax]); end
        end
        xlim(axN,[lo hi]);
        legend(axN,{'Energy Corrected','No Energy Correction'});
        ttl = strtrim(edNPrefix.Value);
        if isempty(ttl), ttl = 'Neutron Spectra'; else, ttl = sprintf('%s Neutron Spectra',ttl); end
        title(axN, ttl);
        grid(axN,'on'); hold(axN,'off');
        S.keV = keV; setappdata(fig,'S',S);
    end

    function saveNeutron()
        S = getappdata(fig,'S'); lblNeuSave.Text='';
        if ~isfield(S,'neutron_processed_E') || ~isfield(S,'neutron_processed_noE')
            lblNeuSave.Text='Plot neutron spectra first.'; lblNeuSave.FontColor=[.8 .1 .1]; return;
        end
        if ~isfield(S,'path') || ~isfolder(S.path), S.path = pwd; end
        prefix = strtrim(edNPrefix.Value); if isempty(prefix), prefix = 'neutron'; end
        try
            data = struct( ...
                'LMmap_Ecorrect',   S.neutron_processed_E, ...
                'LMmap_noEcorrect', S.neutron_processed_noE, ...
                'keV',              S.keV );
            fP = fullfile(S.path,[prefix '_final.mat']);
            save(fP, '-struct', 'data');
            lblNeuSave.Text=sprintf('Processed neutron data saved: %s', fP);
            lblNeuSave.FontColor=[.1 .5 .1];
        catch ME
            lblNeuSave.Text=['Save error: ' ME.message];
            lblNeuSave.FontColor=[.8 .1 .1];
        end
    end
end

%% =================== Helpers ===================

function y = smoothVector(y, method, span)
    y = double(y);
    n = numel(y);
    if n < 5 || ~isfinite(span) || span <= 0
        return;
    end

    switch method
        case 'moving'
            window = max(3, round(span*n));
            y = smoothdata(y, 'movmean', window);
        case {'loess','lowess'}
            window = max(5, makeOdd(round(span*n)));
            y = smoothdata(y, method, window);
        case 'sgolay'
            window = max(5, makeOdd(round(span*n)));
            y = smoothdata(y, 'sgolay', window);
        case 'filtfilt'
            if exist('butter','file') == 2 && exist('filtfilt','file') == 2
                [bf,af] = butter(4,0.05);
                y = filtfilt(bf,af,y);
            else
                window = max(5, makeOdd(round(span*n)));
                y = smoothdata(y, 'movmean', window);
            end
        otherwise
            window = max(5, makeOdd(round(span*n)));
            y = smoothdata(y, 'movmean', window);
    end
end

function rois = isotopeROIs(iso,mode)
    switch iso
        case 'Am-241'
            rois = [250 350];                         % single
        case 'Co-57'                                  % two windows for 122 & 136 keV (pixel gain correction tools)
            rois = [600 700; 720 820];
        case 'Eu-152'
            if strcmp(mode,'HEM')
                rois = [500 600; 800 900];            % two peaks (245 & 344 keV)
            else
                rois = [600 700];                     % single (121.8 keV)
            end
        otherwise
            rois = [600 700];
    end
end

function E = pickKnownEnergies(iso,mode)
    switch iso
        case 'Am-241'
            E = 59.6;
        case 'Co-57'
            E = [122 136];
        case 'Eu-152'
            if strcmp(mode,'HEM'), E = [245 344];
            else,                  E = 121.8;
            end
        otherwise
            E = 122;
    end
end

function rois = chooseIsotopeROIsEnergy(iso,mode,lim)
    switch iso
        case 'Am-241'
            centers = 59.6;   W = 12;     % single
        case 'Co-57'
            centers = 122;    W = 8;      % ONLY 122 keV for FWHM
        case 'Eu-152'
            if strcmp(mode,'HEM')
                centers = [245 344]; W = 15; % two peaks in HEM
            else
                centers = 121.8;     W = 12; % single in LEM
            end
        otherwise
            centers = 122; W = 12;
    end
    centers = centers(:)'; rois = zeros(numel(centers),2);
    for i=1:numel(centers)
        lo = max(lim(1), centers(i)-W);
        hi = min(lim(2), centers(i)+W);
        rois(i,:) = [lo hi];
    end
    rois = rois(rois(:,2)>rois(:,1),:);
end

function n = makeOdd(n)
    if mod(n,2)==0, n=n+1; end
end

function [signChar, absVal] = signedStr(v)
    if v>=0, signChar = '+'; else, signChar = '-'; end
    absVal = abs(v);
end

function saveCurveFitMATs(folder, prefix, x_keV, yE_counts, yN_counts)
    if ~isfolder(folder), folder = pwd; end
    x = x_keV(:); y = yE_counts(:);
    save(fullfile(folder, sprintf('%s_E_curvefit.mat',   prefix)), 'x','y');
    x = x_keV(:); y = yN_counts(:);
    save(fullfile(folder, sprintf('%s_NoE_curvefit.mat', prefix)), 'x','y');
end
