function guesses=Guessing(mov_fname,mov,movsz,goodframe,dfrlmsz,...
    bpthrsh,egdesz,pctile_frame,debugmode,mask_fname,make_guessmovie)
%% Guessing
% make a list of guesses for sinlge molecules. Using a bandpass filter to
% filter pixel noise first, then uses bwpropfilt to find blobs of the
% correct size
%
%%%% Inputs %%%%
% mov_fname is the full filename of the movie to be analyzed for output
% file naming purposes
%
% mov is the movie data as a 3D array where the third dimension is the
% frame number.
%
% movsz is the output of size(mov)
%
% goodframe is an optional logical vector indicating which frames are to be
% ignored. The length of the goodframe vector should be the number of
% frames in mov. To ignore a frame set the corresponding element in
% goodframe to false.
%
% dfrlmsz is the  size of a diffraction limited spot in pixels. It's the
% nominal diameter, NOT the FWHM or something similar. Integer please!
%
% bpthrsh is the the percentile of brightnesses of the bandpassed image
% below which those pixels will be ignored.
%
% edgesz is the number of pixels on the edge of the image that will be
% ignored.
%
% pctile_frame is a boolean determining whether bpthrsh will be applied
% frame by frame, or to the entire movie. Using the entire movie (setting
% to 0) is more sensitive to low frequency noise and background changes,
% but is a more robust guessing method. Using each frame tends to produce a
% constant number of guesses per frame, regardless of their absolute
% brightness.
%
% debugmode is a boolean to determine if you want to go through and look at
% the guesses.
%
% mask_fname is the filename of a mask to use for guessing. If no mask is
% being used just leave it empty. If mask_fname is set 1, then the program
% will look for a file in the same directory as the movie with '_PhaseMask'
% appened to the name of the movie. The mask is a .mat file which has a
% logical array (or at least where nonzero entries will be converted to 1s)
% called PhaseMask that is the same size as a frame in the current movie.
%
% make_guessmovie is a Boolean determining whether or not to make a .avi
% movie of the guesses. This can be helpful to determine how successful the
% guessing was.
%
%%%% Outputs %%%%
% guesses is an array with columns 1. frame #, 2. row #, 3. column # of the
% guesses
%
% The program currently also writes a .mat file with guesses and all of the
% user parameters saved.
%
%
%%%% Dependencies %%%%
% bpass
%
%     Copyright (C) 2017  Benjamin P Isaacoff
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
%
%
%did you not set dfrlmsz to an integer?
if dfrlmsz~=round(dfrlmsz);error('dfrlmsz must be an integer');end

%pad size for the bandpass function
pdsz=50;
global verbose
tic;%for measuring the time to run the entire program
% last updated 3/10/18 BPI
%% Setup

[pathstr,fname] = fileparts(mov_fname);
if verbose
    disp([char(datetime),'   Making guesses for ',fname])
end
%intializing the guess indices cell array
guesses=zeros(1,3);
roinum=0;
%% Guessing

%making the phasemask logical map
if ~isempty(mask_fname)
    if ischar(mask_fname)
        %the strrep is to get rid of the avgsub, note that this shouldn't
        %do anything if bgsub=0
        try
            load([pathstr,filesep,mask_fname,'.mat'],'PhaseMask')
        catch
            [datalist,dataloc,~]=uigetfile([pathstr,filesep,'*.*']);
            if ~iscell(datalist); datalist={datalist}; end
            datalist=[dataloc datalist];
            [dlocs,dnames,~]=cellfun(@fileparts,datalist,'uniformoutput',false);
            load([dlocs{1,1},filesep,dnames{1,2}],'PhaseMask')
        end
    else
        load([pathstr,filesep,strrep(fname,'_avgsub',[]),'_PhaseMask.mat'],'PhaseMask')
        
    end
    PhaseMasklg=PhaseMask;
    PhaseMasklg(PhaseMasklg~=0)=1;
    PhaseMasklg=logical(PhaseMasklg);
else
    PhaseMasklg=true(movsz([1,2]));
    PhaseMask=true(movsz([1,2]));
end

%using the percentiles on the entire movie
if ~pctile_frame
    %initializing the bandpassed movie
    bimgmov=zeros(movsz);
    goodfrmmov=false(movsz);
    %looping through and making the bandpassed movie
    for ll=1:movsz(3)
        if goodframe(ll)
            goodfrmmov(:,:,ll)=true;
            %padding the current frame to avoid the Fourier ringing
            %associated with the edges of the image
            curfrm=padarray(mov(:,:,ll),[pdsz,pdsz],'symmetric');
            
            %bandpass parameters
            LP=2;%lnoise, should always be 1
            HP=round(dfrlmsz*1.5);%lobject, set by diffraction limit
            T=0;%threshold, now always zero
            lzero=egdesz;%how many pixels around the edge should be ignored, optional
            %bandpass it
            bimg=bpass(curfrm,LP,HP,T,lzero+pdsz);
            %removed the padded pixels around the edge
            bimgmov(:,:,ll)=bimg((pdsz+1):(movsz(1)+pdsz),(pdsz+1):(movsz(2)+pdsz));
        end
    end
    
    %convert it to a logical movie by thresholding with the bpthrsh
    %percentile of the brightnesses for nonzero pixels
    bimgmov=logical(bimgmov.*(bimgmov>prctile(bimgmov(bimgmov>0 & ...
        goodfrmmov & repmat(PhaseMasklg,[1,1,movsz(3)])),bpthrsh)).*repmat(PhaseMasklg,[1,1,movsz(3)]));
end

if make_guessmovie
    v = VideoWriter([pathstr,filesep,fname,'_Guesses.avi'],'Uncompressed AVI');
    open(v);
    
    disp(['Making guesses movie for ',fname]);
end

for ll=1:movsz(3)
    if goodframe(ll)
        %using the percentile on each frame
        if pctile_frame
            %padding the current frame to avoid the Fourier ringing
            %associated with the edges of the image
            curfrm=mov(:,:,ll);
            
            curfrmbp=padarray(curfrm,[pdsz,pdsz],'symmetric');
            
            %bandpass parameters
            LP=1;%lnoise, should always be 1
            HP=round(dfrlmsz*1.5);%lobject, set by diffraction limit
            T=0;%threshold, now always zero
            lzero=egdesz;%how many pixels around the edge should be ignored, optional
            %bandpass it
            bimg=bpass(curfrmbp,LP,HP,T,lzero+pdsz);
            %pull out the actual data
            bimg=bimg((pdsz+1):(movsz(1)+pdsz),(pdsz+1):(movsz(2)+pdsz));
            
            %threshold with the bpthrsh percentile of the brightnesses for
            %nonzero pixels, then turn it into a logical array
            logim=logical(bimg.*(bimg>prctile(bimg(bimg>0 & PhaseMasklg),bpthrsh)).*PhaseMasklg);
        else
            logim=bimgmov(:,:,ll);
        end
        
        %search for shapes with an EquivDiameter of floor(dfrlmsz/2) to
        %2*dfrlmsz
        bw2=bwpropfilt(logim,'EquivDiameter',[floor(dfrlmsz/2),2*dfrlmsz]);
        rgps=regionprops(bw2,'centroid');% find the centroids of those shapes
        centroids = cat(1, rgps.Centroid);%just rearraging the array
        %filling the array for this frame
        if ~isempty(centroids)
            guesses=cat(1,guesses,[repmat(ll,size(centroids(:,2))),round(centroids(:,2)),round(centroids(:,1))]);
            roinum=[roinum;diag(PhaseMask(round(centroids(:,2)),round(centroids(:,1))))];
        end
        
        if debugmode || make_guessmovie %plot the guesses, for checking parameters
            if ~pctile_frame
                curfrm=mov(:,:,ll);
            end
            imshow(double(curfrm),prctile(double(curfrm(curfrm>0)),[.1,99.8]))
            if ~isempty(centroids)
                %viscircles is reversed
                vcs=viscircles([centroids(:,1),centroids(:,2)],repmat(dfrlmsz,[length(centroids(:,2)),1]));
                set(vcs.Children,'LineWidth',1)
            end
            if debugmode
                title([fname,'   frame ',num2str(ll)],'Interpreter','none')
                keyboard
            elseif make_guessmovie
                frame = getframe;
                writeVideo(v,frame);
            end
        end
    end
end
guesses=guesses(2:end,:);%get rid of first row of zeros
roinum(1)=[];
if make_guessmovie
    close(v)
    keyboard
end

tictoc=toc;%the time to run the entire program

[pathstr,name,~] = fileparts(mov_fname);
save([pathstr,filesep,name,'_guesses.mat'],'guesses','goodframe','dfrlmsz','egdesz','pctile_frame','bpthrsh',...
    'movsz','tictoc','mask_fname','roinum','-v7.3');

end










