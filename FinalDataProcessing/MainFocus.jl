# The code to fuse images will be located here
include("Datastructures.jl")
using .Datastructures
include("./IO_dp.jl")
import .IO_dp

include("./ContrastFunctions.jl")
import .ContrastFunctions
include("./Grey_Projectors.jl")
import .GreyProjectors
include("./ImageFusion.jl")
import .ImageFusion

using Base.Threads
using Images
using IterTools
using ProgressMeter


batch_size = 8
path = "/Images/img_0/"
save_path = "/SaveSpot/FakeBee2/"
blackpoint = [0,0,0]
contrast_precision = Float32 
width = 2028 #3040 RAW data rn
height =  1520# 4056
debug = false

function restart_with_threads(num_threads)
    ENV["JULIA_NUM_THREADS"] = string(num_threads)
    println("Restarting Julia with $num_threads threads...")
    run(`$(Base.julia_cmd()) -t $num_threads -e 'println("Running with ", Threads.nthreads(), " threads")'`)
end

# Restart with number of threads
if nthreads() == 1
    num_threads = batch_size
    # Overwrite in case there is too many and risks getting killed
    if batch_size >= Sys.CPU_THREADS
        num_threads = Sys.CPU_THREADS - 1
    end
    restart_with_threads(num_threads)
end

pp = Datastructures.ProcessingParameters(contrast_precision, ContrastFunctions.LoG, GreyProjectors.lstar, blackpoint, path, save_path,width, height, debug)


function FocusFusion(parameters::Datastructures.ProcessingParameters,batch_size::Int,tst::Bool=false)
    # Print process ID for debugging purposes
    println("PID: $(getpid())")
    overallStart = time()
    if tst # When profiling need to run once to initialize
        return
    end
    # Fix paths
    parameters.path         = IO_dp.FixPath(parameters.path)
    parameters.save_path    = IO_dp.FixPath(parameters.save_path)

    # Where focus stack recursions will be stored
    intermediary_img_path = parameters.save_path

    # Epsilons in case of Nans (assumed) resulting from the weight matrix scaling
    epsilons = [1e-12,1e-10, 1e-8, 1e-6]
    printstyled("Running with $(nthreads()) threads\n", color=:blue)
    # Number of times fusion may fail (needs the same number of epsilons)
    allowed_fail= 4 
    # Grab image identifiers
    ImagingGrid = IO_dp.GrabIdentifiers(parameters.path)
    #Temp override
    #ImagingGrid.exp = ["NoIR"]
    #ImagingGrid.y =[0]
    #ImagingGrid.z = [0]


    # Iterate the imaging grid
    total = length(ImagingGrid.y)*length(ImagingGrid.z)*length(ImagingGrid.exp)
    counter = 0
    
    ignore = []

    if !isdir(joinpath(parameters.save_path)) 
        mkdir(joinpath(parameters.save_path))
    end

    # Parse meta file for contrast values if available and create filtering array
    contrast_max, contast_min, contrast_mean,indexing_array,conv_dicts = nothing,nothing,nothing,nothing,nothing

    if isfile(joinpath(parameters.path, "meta.txt"))
        println("Loading meta.txt to filter images by contrast")
        # Conv dicts is a tupple of dictionaries to find the index of coordinates each has the form coord => index
        contrast_max, contast_min, contrast_mean,conv_dicts = IO_dp.ParseMetaFile(joinpath(parameters.path, "meta.txt"))
        # TODO: Below uses max vals for min threshholds as I computed the statistics for mean wrong, this will work accross runs
        cont_method = 1 
        indexing_array = IO_dp.GenerateImageIgnoreListContrast(contrast_max, contast_min, contrast_mean, cont_method)
    end

    for ei in ImagingGrid.exp
    for yi in ImagingGrid.y
    for zi in ImagingGrid.z
        counter += 1
        final_name = IO_dp.GenerateFinalFileName(yi,zi,ei)
        success = false
        # Check file doesnt exist, we arent in debug, and check if the file is to be ignored (missing data)
        if ((!isfile("$(save_path)$(final_name)") || parameters.debug) && !(final_name in ignore))
            start = time()
            println()
            printstyled("Processing image $(counter) out of $(total)\n", color=:blue)
            # Generate file names
            if isnothing(indexing_array)  fnames = [IO_dp.GenerateFileName(xi,yi,zi,ei) for xi in ImagingGrid.x]
            else  fnames = [IO_dp.GenerateFileName(xi,yi,zi,ei) for xi in ImagingGrid.x if indexing_array[conv_dicts[1][xi],conv_dicts[2][yi],conv_dicts[3][zi]]]
            end
            # Filter based on files available and make full path
            fnames =  [joinpath(parameters.path,i) for i in fnames if isfile(joinpath(parameters.path, i)) ]
            # Run stacking for yze postion and split them as too much ram is used
            println("File count $(length(ImagingGrid.x))/$(length(fnames))")
            counter_ = 0
            #Use save directory as ssd full
            if !isdir(joinpath(intermediary_img_path, "$(yi)_$(zi)_$(ei)")) 
                mkdir(joinpath(intermediary_img_path, "$(yi)_$(zi)_$(ei)"))
            end
            function partition_image_array(iterable, n)
                partitions = []
                i = 1
                while i <= length(iterable)
                    end_idx = min(i + n - 1, length(iterable))
                    push!(partitions, iterable[i:end_idx])
                    i += n
                end
                return partitions
            end
            function BatchedMKR(fnames, pp, batch_size, prev_path, yi,zi,ei, progress_bar)
                """
                Function for automatic recursion of the dataset, ie process images in batch size until none left
                fnames -> Full path file + file names for processing
                pp -> processing parameters for MKR
                batch_size -> Maximum number of images to run MKR on
                prev_path -> The path under which to creaet the new out directory
                """
                out_fnames = []
                if length(fnames) <= batch_size
                    #TODO: Make final image
                    fail_count = 1
                    while fail_count <= allowed_fail
                        image = ImageFusion.MKR(fnames, parameters, epsilons[fail_count])
                        next!(progress_bar)
                        if any(isnan.(image))
                            fail_count += 1
                        else
                            return image
                        end 
                    end
                else
                    # Set new path make dir if doesnt exist
                    curr_save_dir = joinpath(prev_path, "$(yi)_$(zi)_$(ei)") 
                    if !isdir(curr_save_dir)
                        mkdir(curr_save_dir)
                    end
                    counter_ = 0
                    # Dont use itertools -> Doesnt supply remainder elements
                    for batch in partition_image_array(fnames, batch_size)
                        # Now we handled file and dir existance and locations
                        outname = joinpath(curr_save_dir, "im_$(counter_).png")
                        push!(out_fnames, outname) # Push fname now to avoid clash with isfile
                        if !isfile(outname) 
                        fail_count = 1
                        # Do MKR with fail check
                        while fail_count <= allowed_fail
                            image = ImageFusion.MKR(batch, parameters, epsilons[fail_count])
                            if any(isnan.(image))
                                fail_count += 1
                            else
                                Images.save(outname, image)
                                next!(progress_bar)
                                break
                            end
                        end # Fail check
                        end # Is file
                        counter_ += 1
                    end # Batch
                end # fnames size check
                # Start new iteration 
                return BatchedMKR(out_fnames, pp, batch_size, curr_save_dir, yi, zi, ei,progress_bar)
            end # function
            function compute_total_iterations(image_count::Int, batch_size::Int)
                """Compute how many times in total batched MKR will be called"""
                total_iterations = 0
                current_images = image_count
                while current_images > 1
                    iterations_at_level = ceil(Int, current_images / batch_size)
                    total_iterations += iterations_at_level
                    current_images = iterations_at_level
                end
                return total_iterations
            end # function
            # And run the iteration function with pretty print
            p = Progress(compute_total_iterations(length(fnames), batch_size), "$(final_name)",1)
            image = BatchedMKR(fnames, pp, batch_size, intermediary_img_path, yi,zi,ei,p)
            # Save the Image
            savepath = joinpath(parameters.save_path, final_name)
            Images.save(savepath, image)

        else # Handle ignore and exist
            if final_name in ignore
                printstyled("$(final_name) to ignore as specified\n", color=:red)
            else
                printstyled("   $(final_name) already exists, skipping\n", color=:yellow)
            end
        end
    end
    end
    end
    println("Time taken for all $(overallStart-time())")
end

# Profiling
using Profile
#using ProfileView # using porfile view
#ProfileView.set_theme!(:dark)
#ProfileView.@profview FocusFusion(pp)
using PProf # Using PProf

if isinteractive()
    # Profilling - Runs only in repl
    
    Profile.clear()
    @profile FocusFusion(pp)
    pprof()
else
    FocusFusion(pp, batch_size)
end