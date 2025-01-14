function  fits=Subtract_then_fit(mov_fname,mov,movsz,...
    off_frames,moloffwin,guesses,roinum,dfrlmsz,MLE_fit,stdtol,...
    maxerr,do_avgsub,which_gaussian,fit_ang,usegpu)
%% Subtract_mol_off_frames
% subtracts the average (or median) intensity of off frames for each guess
% stored in Mol_off_frames_fname.
%
% If you just want to do fitting, and not do background subtraction, set
% off_frames = 'nobgsub'. The program will take care of everything else.
%
%%%% Inputs %%%%
% mov_fname the filename of the movie
%
% mov is the movie data as a 3D array where the third dimension is the
% frame number.
%
% movsz is the output of size(mov)
%
% off_frames is the ouput from Mol_off_frames.mat which contains the off
% frames list for all guesses.
%
% moloffwin is the number of frames around the current frame to use for the
% BGSUB
%
% guesses is guesses array from Guessing.mat
%
% dfrlmsz is the  size of a diffraction limited spot in pixels. It's the
% nominal diameter, NOT the FWHM or something similar. Integer please
%
% MLE_fit  a Boolean determining whether or not MLE fitting is used. Set to
% 1 to use MLE and to 0 to use least squares. Note that MLE is quite slow,
% and so its not recommended for a large number of guesses
%
% stdtol is tolerance on fit Gaussian STD.
%
% maxerr is the maximum error of the fit for MLE fit, using variance
% default 0.1 (can't be above this) for LSQR fit, using the 95% confidence
% interval on the position
%
% do_avgsub is a Boolean determining whether or not to subtract the mean of
% the off frames. Set to 1 to subtract the mean and to 0 to subtract the
% median.
%
% which_gaussian determines what functional form of Gaussian function the
% molecules will be fit to if using least-squares fitting (MLE fitting only
% fits symmetric Gaussian). Set to 1 to use a symmetric Gaussian. Set to 2
% to use an asymmetric Gaussian (with angle determined by fit_ang). Set to
% 3 to use a freely rotating asymmetric Gaussian.
%
% fit_ang is the angle in degrees for an asymmetric Gaussian fit, see above
%
% usegpu is Boolean determining whether or not to use a CUDA enabled GPU
% for fitting if available.
%
%%%% Output %%%%
% a .mat file, importantly containing the fits structure that has fields
%frame number of the fit:
% fits.frame
%row coordinate of the fit:
% fits.row
%column coordinate of the fit:
% fits.col
%standard deviation in the row dimension of the Gaussian fit (if using a
%symmetric Gaussian this will be the same as the other width):
% fits.widthr
%standard deviation in the column dimension of the Gaussian fit (if using a
%symmetric Gaussian this will be the same as the other width):
% fits.widthc
%angle of asymmetric Gaussian fit:
% fits.ang
%offset of Gaussian fit:
% fits.offset
%amplitude of Gaussian fit:
% fits.amp
%error on fit (for MLE fitting, this is the variance, for least squares
%fitting, this is the mean 95% confidence interval on the position):
% fits.err
%sum of pixels in ROI around guess:
% fits.sum
%goodfit boolean:
% fits.goodfit
%
%%%% Dependencies %%%%
% TIFFStack 
% MLEwG (for MLE fitting) 
% gaussfit (for least squares fitting)
% gpufit
%
%     Copyright (C) 2018  Benjamin P Isaacoff
%
%     This program is free software: you can redistribute it and/or modify
%     it under the terms of the GNU General Public License as published by
%     the Free Software Foundation, either version 3 of the License, or (at
%     your option) any later version.
%
%     This program is distributed in the hope that it will be useful, but
%     WITHOUT ANY WARRANTY; without even the implied warranty of
%     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%     General Public License for more details.
%
%     You should have received a copy of the GNU General Public License
%     along with this program.  If not, see <http://www.gnu.org/licenses/>.
%
subnfit=tic;%for measuring the time to run the entire program

[pathstr,fname] = fileparts(mov_fname);

disp([char(datetime),'   Fitting ',fname])

% plot_on is for debugging
plot_on=0;
% check if a GPU is available
if usegpu
    usegpu=parallel.gpu.GPUDevice.isAvailable;
end
if usegpu
    mov=single(mov);
end
%check that the bgsub is actually happening
bgsub=1;
if strcmp(off_frames,'nobgsub');bgsub=0;end
if bgsub
    %check number of fits vs length of off frames
    if size(guesses,1)~=numel(off_frames);error('Unequal number of fits and number of off frames lists');end
end
%% The Averaging and Subtraction

%the conversion between dfrlmsz and the STD of the Gaussian, reccomended
%using the full width at 20% max given by (2*sqrt(2*log(5)))
dfD2std=(2*sqrt(2*log(5)));
%the guessed std
gesss=dfrlmsz/dfD2std;

% Use a CUDA enabled GPU to perform the fitting with GPUfit for significant
% improvement in fitting speed. Otherwise use the CPU to fit.

dataset=single(NaN((dfrlmsz*2+1)^2,size(guesses,1)));
initial_parameters=single(NaN(5,size(guesses,1)));
molr=guesses(:,2);
molc=guesses(:,3);
fits.frame=guesses(:,1);
fits.molid=(1:size(guesses,1))';
framelist=guesses(:,1);
if MLE_fit && usegpu
offset=NaN(1,size(guesses,1));
end
%looping through all the guesses
if bgsub
    for ii=1:size(guesses,1)
        
        %current frame and molecule position
        curfrmnum=framelist(ii);
        curmolr=molr(ii);
        curmolc=molc(ii);
        frmlst=off_frames{ii};
        
        %the average (or median) frame
        if do_avgsub
            mean_mov=mean(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
        else
            mean_mov=median(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
        end
        %the molecule image
        molim=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
        %the subtracted image
        data=molim-mean_mov;
        data=reshape(data,[],1);
        gessb=min(data(:));
        gessN=range(data(:));
        if MLE_fit && ~usegpu
        %the guessed amplitude, using the formula in MLEwG
        gessN=range(data(:))*(4*pi*gesss^2);
        end
        if usegpu
            params0=[gessN;dfrlmsz;dfrlmsz;gesss;gessb];
        else
            params0=[dfrlmsz,dfrlmsz,gesss,gessb,gessN];
        end
        if MLE_fit && usegpu
            dataset(:,ii)=data+2*abs(min(data));
            offset(1,ii)=2*abs(min(data));
            params0(5)=abs(min(data));
            initial_parameters(:,ii)=params0;
        else
            initial_parameters(:,ii)=params0;
            dataset(:,ii)=data;
        end
    end
else
    for ii=1:size(guesses,1)
        curfrmnum=framelist(ii);
        curmolr=molr(ii);
        curmolc=molc(ii);
        data=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
        data=reshape(data,[],1);
        gessb=min(data(:));
        gessN=range(data(:));
        if MLE_fit && ~usegpu
        %the guessed amplitude, using the formula in MLEwG
        gessN=range(data(:))*(4*pi*gesss^2);
        end
        if usegpu
            params0=[gessN;dfrlmsz;dfrlmsz;gesss;gessb];
        else
            params0=[dfrlmsz;dfrlmsz;gesss;gessb;gessN];
        end
        initial_parameters(:,ii)=params0;
        dataset(:,ii)=data;
    end
end
%%%% Fitting %%%%
if usegpu
    %fitting with gpufit LSE fitting
    tolerance = 1e-4;
    % maximum number of iterations
    max_n_iterations = 1e4;
    % estimator id
    if MLE_fit
        estimator_id = EstimatorID.MLE;
    else
        estimator_id = EstimatorID.LSE;
    end
    % model ID
    if which_gaussian==1
        model_id = ModelID.GAUSS_2D;
        params_to_fit=[];
    elseif which_gaussian==2
        model_id=ModelID.GAUSS_2D_ROTATED;
        initial_parameters(6,:)=fit_ang;
        initial_parameters(5:7,:)=initial_parameters(4:6,:);
        params_to_fit=[1,1,1,1,1,1,0]';
    elseif which_gaussian==3
        model_id=ModelID.GAUSS_2D_ROTATED;
        params_to_fit=[];
        initial_parameters(6,:)=fit_ang;
        initial_parameters(5:7,:)=initial_parameters(4:6,:);
    end
    [parameters, states, chi_squares,~,~] = gpufit(dataset, [], ...
        model_id, initial_parameters, tolerance, max_n_iterations, params_to_fit, estimator_id, []);
    
    fits.amp=parameters(1,:)';
    if MLE_fit
        fits.offset=(parameters(5,:)-offset)';
    else
        fits.offset=parameters(5,:)';
    end
    fits.row=parameters(2,:)'-dfrlmsz+molr;
    fits.col=parameters(3,:)'-dfrlmsz+molc;
    fits.widthr=parameters(4,:)';
    fits.widthc=parameters(4,:)';
    if which_gaussian==1
        fits.ang=zeros(size(guesses,1),1);
    else
        fits.ang=parameters(6,:);
    end
    fits.err=(1-(chi_squares)./(sum((dataset-mean(dataset,1)).^2)))';
    fits.chi_squares=chi_squares';    
    if MLE_fit
        fits.err=(1-chi_squares./sum(2.*((mean(dataset,1)-dataset)-dataset.*log(mean(dataset,1)./dataset))))';
        errbad=fits.err<maxerr | states~=0;
    else
        errbad=fits.err<maxerr;
    end
    if MLE_fit && bgsub
        fits.sum=sum(dataset-offset,1)';
    else
        fits.sum=sum(dataset,1)';
    end
    fits.rowCI=sqrt(((fits.widthr.^2+1/12)./fits.sum)+(4*sqrt(pi()).*fits.widthr.^3.*fits.chi_squares)./(fits.sum.^2)); %Localization error based on Thompson, Larson, and Webb Biophys J. 2002 82 27752783. Equation 14
    fits.colCI=sqrt(((fits.widthc.^2+1/12)./fits.sum)+(4*sqrt(pi()).*fits.widthc.^3.*fits.chi_squares)./(fits.sum.^2)); %Where s is the gaussian width, a is the pixel size, N is the integrated intensity, and b^2 is the fit error (chi-squares), all spatial units are in pixels

    %determining if it's a goodfit or not (remember this field was
    %initialized to false)
    fits.goodfit=false(size(guesses,1),1);
    for ii=1:size(guesses,1)
        if (mean([fits.widthr(ii),fits.widthc(ii)])<=(stdtol*gesss) && mean([fits.widthr(ii),fits.widthc(ii)])>=(gesss/stdtol)) && ... %Compare width with diffraction limit
                ~errbad(ii) && ... %too much error on fit?
                fits.amp(ii)<fits.sum(ii) && ... %the amplitude of the fit shouldn't be bigger than the integral
                ~any([fits.row(ii),fits.col(ii),fits.amp(ii),fits.sum(ii)]<0) && ... %none of the fitted parameters should be negative, except the offset!
                fits.rowCI(ii)<=dfrlmsz && fits.colCI(ii)<=dfrlmsz %none of the localization errors are larger than the gaussian widths
            fits.goodfit(ii)=true;%goodfit boolean
        end
    end
    fits.states=states';
    %plotting for debugging/tests
    if plot_on
        for kk=1:size(guesses,1)
            curfrmnum=framelist(kk);
            curmolr=molr(kk);
            curmolc=molc(kk);
            frmlst=off_frames{kk};
            
            if bgsub
                %the average (or median) frame
                if do_avgsub
                    mean_mov=mean(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
                else
                    mean_mov=median(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
                end
                %the molecule image
                molim=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
                %the subtracted image
                data=molim-mean_mov;
                
                h12=figure(12);
                subplot(1,4,1)
                imshow(mean_mov,[])
                title('Mean BG')
                subplot(1,4,2)
                imshow(molim,[])
                title('Raw Molecule')
                subplot(1,4,3)
                imshow(data,[])
                title('BGSUB')
                
                [x, y] = ndgrid(0:size(data,1)-1,0:size(data,2)-1);
                fitim=gaussian_2d(x, y, parameters(:,kk));
                subplot(1,4,4)
                imshow(fitim,[])
                title('Fit Profile')
                annotation('textbox', [0 0.9 1 0.1], ...
                    'String', ['Frame # ',num2str(curfrmnum),'   Guess # ',num2str(kk),' R^2=',num2str(fits.err(kk))], ...
                    'EdgeColor', 'none', ...
                    'HorizontalAlignment', 'center')
                
                keyboard
                try
                    close(h12)
                catch
                end
            else
                data=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
                h12=figure(12);
                subplot(1,2,1)
                imshow(data,[])
                title('Molecule Image')
                [x, y] = ndgrid(size(data));
                fitim=gaussian_2d(x, y, parameters(:,kk));
                subplot(1,2,2)
                imshow(fitim,[])
                title('Fit Profile')
                annotation('textbox', [0 0.9 1 0.1], ...
                    'String', ['Frame # ',num2str(curfrmnum),'   Guess # ',num2str(kk),' R^2=',num2str(fits.err(kk))], ...
                    'EdgeColor', 'none', ...
                    'HorizontalAlignment', 'center')
                
                keyboard
                try
                    close(h12)
                catch
                end
            end
        end
    end
    
    
else
    %initializing the fits structure
    fits.row=NaN(size(guesses,1),1);%row coordinate of the fit
    fits.col=NaN(size(guesses,1),1);%column coordinate of the fit
    fits.widthr=NaN(size(guesses,1),1);%standard deviation in the row dimension of the Gaussian fit
    fits.widthc=NaN(size(guesses,1),1);%standard deviation in the column dimension of the Gaussian fit
    fits.ang=NaN(size(guesses,1),1);%angle of asymmetric Gaussian fit
    fits.offset=NaN(size(guesses,1),1);%offset
    fits.amp=NaN(size(guesses,1),1);%amplitude of Gaussian fit
    fits.err=NaN(size(guesses,1),1);%error on fit
    fits.sum=sum(dataset,1)';%sum of pixels in ROI around guess
    fits.goodfit=false(size(guesses,1),1);%goodfit boolean
    goodfit=false(size(guesses,1),1);%goodfit boolean
    sumsum=fits.sum;
    fit_sd_r=NaN(size(guesses,1),1);
    fit_sd_rCI=NaN(size(guesses,1),1);
    fit_sd_c=NaN(size(guesses,1),1);
    fit_sd_cCI=NaN(size(guesses,1),1);
    fit_off=NaN(size(guesses,1),1);
    fit_offCI=NaN(size(guesses,1),1);
    fit_amp=NaN(size(guesses,1),1);
    fit_ampCI=NaN(size(guesses,1),1);
    fit_err=NaN(size(guesses,1),1);
    act_r=NaN(size(guesses,1),1);
    act_rCI=NaN(size(guesses,1),1);
    fit_ang=NaN(size(guesses,1),1);
    fit_angCI=NaN(size(guesses,1),1);
    act_c=NaN(size(guesses,1),1);
    act_cCI=NaN(size(guesses,1),1);
    parfor ii=1:size(guesses,1) %
        if MLE_fit
            %fitting with MLE
            [paramsF,varianceF] = MLEwG (reshape(dataset(:,ii),[2*dfrlmsz+1,2*dfrlmsz+1]),initial_parameters(:,ii)',1,plot_on,1);
            %shifting
            paramsF([1,2])=paramsF([1,2])+0.5;
            fit_r=paramsF(1);fit_c=paramsF(2);
            fit_sd_r(ii)=paramsF(3);fit_sd_c(ii)=paramsF(3);
            %recalculating the values based on their equations to match
            paramsF(5)=paramsF(5)/(2*pi*paramsF(3)^2);
            if paramsF(4)>=0
                paramsF(4)=sqrt(paramsF(4));
            else
                paramsF(4)=-sqrt(-paramsF(4));
            end
            fit_off(ii)=paramsF(4);
            fit_amp(ii)=paramsF(5);
            fit_ang(ii)=0;
            fit_err(ii)=varianceF;
            errbad=varianceF>maxerr;%too much error on fit?
        else
            %fitting with least squares
            [fitPars,conf95,~,~,resid]=gaussFit(double(reshape(dataset(:,ii),[2*dfrlmsz+1,2*dfrlmsz+1])),'searchBool',0,'nPixels',2*dfrlmsz+1,...
                'checkVals',0,'ffSwitch',which_gaussian);
            %converting the variables to match the output of MLEwG, and
            %arranging for each particular Gaussian fit
            fit_r=fitPars(1);fit_c=fitPars(2);
            if which_gaussian==1
                fit_sd_r(ii)=fitPars(3);fit_sd_c(ii)=fitPars(3);
                fit_off(ii)=fitPars(5);
                fit_amp(ii)=fitPars(4);
                fit_ang(ii)=0;
                fit_sd_rCI(ii)=conf95(3);fit_sd_cCI(ii)=conf95(3);
                fit_offCI(ii)=conf95(5);
                fit_ampCI(ii)=conf95(4);
                fit_angCI(ii)=0;
            elseif which_gaussian==2
                fit_sd_r(ii)=fitPars(3);fit_sd_c(ii)=fitPars(4);
                fit_sd_rCI(ii)=conf95(3);fit_sd_cCI(ii)=conf95(4);
                fit_off(ii)=fitPars(6);
                fit_offCI(ii)=conf95(6);
                fit_amp(ii)=fitPars(5);
                fit_ampCI(ii)=conf95(5);
                fit_ang(ii)=0;
                fit_angCI(ii)=0;
            elseif   which_gaussian==3
                fit_sd_r(ii)=fitPars(4);fit_sd_c(ii)=fitPars(5);
                fit_sd_rCI(ii)=conf95(4);fit_sd_cCI(ii)=conf95(5);
                fit_off(ii)=fitPars(7);
                fit_offCI(ii)=conf95(7);
                fit_amp(ii)=fitPars(6);
                fit_ampCI(ii)=conf95(6);
                fit_ang(ii)=fitPars(3);
                fit_angCI(ii)=conf95(3);
            end
            fit_err(ii)=1-(sum(resid.^2)/sum((dataset(:,ii)-mean(dataset(:,ii))).^2));
            errbad=fit_err(ii)<maxerr;%too much error on fit?
        end
        %Convert back into full frame coordinates, NOTE the -1!
        act_r(ii)=fit_r-dfrlmsz-1+molr(ii);
        act_c(ii)=fit_c-dfrlmsz-1+molc(ii);
        act_rCI(ii)=conf95(1);
        act_cCI(ii)=conf95(2);
        if (mean([fit_sd_r(ii),fit_sd_c(ii)])<=(stdtol*gesss) && mean([fit_sd_r(ii),fit_sd_c(ii)])>=(gesss/stdtol)) && ... %Compare width with diffraction limit
                ~errbad && ... %too much error on fit?
                fit_amp(ii)<sumsum(ii) && ... %the amplitude of the fit shouldn't be bigger than the integral
                ~any([fit_r,fit_c,fit_amp(ii),sumsum(ii)]<0) %none of the fitted parameters should be negative, except the offset!
            
            goodfit(ii)=true;%goodfit boolean
        else
            goodfit(ii)=false;
        end
        %The sum(:) of the the data
    end
    
    
    %putting the fit results into the fits structure
    fits.row=act_r;%row coordinate of the fit
    fits.rowCI=act_rCI;%row coordinate confidence interval of the fit
    fits.col=act_c;%column coordinate of the fit
    fits.colCI=act_cCI;%column coordinate of the fit
    fits.widthr=fit_sd_r;%standard deviation in the row dimension of the Gaussian fit
    fits.widthrCI=fit_sd_rCI;%standard deviation in the row dimension of the Gaussian fit
    fits.widthc=fit_sd_c;%standard deviation in the column dimension of the Gaussian fit
    fits.widthcCI=fit_sd_cCI;%standard deviation in the column dimension of the Gaussian fit
    fits.ang=fit_ang;%angle of asymmetric Gaussian fit
    fits.angCI=fit_angCI;%Confidence interval of angle of asymmetric Gaussian fit
    fits.offset=fit_off;%offset
    fits.offsetCI=fit_offCI;%Confidence interval of offset
    fits.amp=fit_amp;%amplitude of Gaussian fit
    fits.ampCI=fit_ampCI;%Confidence interval of amplitude of Gaussian fit
    fits.err=fit_err;%error on fit
    fits.goodfit=goodfit;%determining if it's a goodfit or not (remember this field was
    %initialized to false)
    
    
    %plotting for debugging/tests
    if plot_on
        for ii=1:size(guesses,1)
            curfrmnum=framelist(ii);
            curmolr=molr(ii);
            curmolc=molc(ii);
            frmlst=off_frames{ii};
            
            if bgsub
                %the average (or median) frame
                if do_avgsub
                    mean_mov=mean(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
                else
                    mean_mov=median(single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),frmlst)),3);
                end
                %the molecule image
                molim=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
                %the subtracted image
                data=molim-mean_mov;
                
                h12=figure(12);
                subplot(1,4,1)
                imshow(mean_mov,[])
                title('Mean BG')
                subplot(1,4,2)
                imshow(molim,[])
                title('Raw Molecule')
                subplot(1,4,3)
                imshow(data,[])
                title('BGSUB')
                [x, y] = ndgrid(1:size(data,1),1:size(data,2));
                fitim=gaussian_2d(x, y, [fits.amp(ii),fits.row(ii),fits.col(ii),fits.widthc(ii),fits.offset(ii)]');
                subplot(1,4,4)
                imshow(fitim,[])
                title('Fit Profile')
                annotation('textbox', [0 0.9 1 0.1], ...
                    'String', ['Frame # ',num2str(curfrmnum),'   Guess # ',num2str(ii),' R^2=',num2str(fits.err)], ...
                    'EdgeColor', 'none', ...
                    'HorizontalAlignment', 'center')
                
                keyboard
                try
                    close(h12)
                catch
                end
            else
                data=single(mov(curmolr+(-dfrlmsz:dfrlmsz),curmolc+(-dfrlmsz:dfrlmsz),curfrmnum));
                h12=figure(12);
                subplot(1,2,1)
                imshow(data,[])
                title('Molecule Image')
                [x, y] = ndgrid(size(data));
                fitim=gaussian_2d(x, y, parameters(:,ii));
                subplot(1,2,2)
                imshow(fitim,[])
                title('Fit Profile')
                annotation('textbox', [0 0.9 1 0.1], ...
                    'String', ['Frame # ',num2str(curfrmnum),'   Guess # ',num2str(ii),' R^2=',num2str(fits.err(ii))], ...
                    'EdgeColor', 'none', ...
                    'HorizontalAlignment', 'center')
                
                keyboard
                try
                    close(h12)
                catch
                end
            end
        end
    end
end
tictoc=toc(subnfit);%the time to run the entire program
%save the data
fits.roinum=roinum;
if bgsub
    fname=[pathstr,filesep,fname,'_AccBGSUB_fits.mat'];
else
    fname=[pathstr,filesep,fname,'_fits.mat'];
end
save(fname,'fits','MLE_fit','stdtol','maxerr','dfrlmsz','movsz','moloffwin',...
    'tictoc','do_avgsub','which_gaussian','-v7.3')

end

function g = gaussian_2d(x, y, p)
% Generates a 2D Gaussian peak.
% http://gpufit.readthedocs.io/en/latest/api.html#gauss-2d
%
% x,y - x and y grid position values p - parameters (amplitude, x,y center
% position, width, offset)

g = p(1) * exp(-((x - p(2)).^2 + (y - p(3)).^2) / (2 * p(4)^2)) + p(5);

end
