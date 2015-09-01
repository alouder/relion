#include "src/gpu_utils/cuda_ml_optimiser.h"
#include "src/gpu_utils/cuda_projector.h"
#include "src/gpu_utils/cuda_projector.cuh"
#include "src/gpu_utils/cuda_benchmark_utils.cuh"
#include "src/gpu_utils/cuda_kernels/helper.cuh"
#include "src/gpu_utils/cuda_kernels/diff2.cuh"
#include "src/gpu_utils/cuda_kernels/wavg.cuh"
#include <sys/time.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <ctime>
#include <iostream>
#include "src/complex.h"
#include <fstream>
#include <cuda_runtime.h>
#include "src/parallel.h"
#include <signal.h>

/*
 * This assisting function goes over the orientations determined as significant for this image, and checks
 * which translations should be included in the list of those which differences will be calculated for.
 *
 * Any contiguous translations with a shared orientation are grouped together into a "job" which is supplied
 * to the difference kernel. If there are more contiguous translations than the specified PROJDIFF_CHUNK_SIZE,
 * these are split into separate jobs, to increase paralllelism at the cost of redundant memory reads.
 */
long int makeJobsForDiff2Fine(
		OptimisationParamters &op,  SamplingParameters &sp,
		long int orientation_num, long int translation_num,
		ProjectionParams &FineProjectionData,
		std::vector< long unsigned > &iover_transes,
		std::vector< long unsigned > &ihiddens,
		long int nr_over_orient, long int nr_over_trans, int ipart,
		IndexedDataArray &FPW, // FPW=FinePassWeights
		IndexedDataArrayMask &dataMask)
{
	long int w_base = dataMask.firstPos, w(0), k(0);
	// be on the safe side with the jobArrays: make them as large as they could possibly be
	// (this will be reduced at exit of this function)
	dataMask.setNumberOfJobs(orientation_num*translation_num);
	dataMask.setNumberOfWeights(orientation_num*translation_num);
	dataMask.jobOrigin.host_alloc();
	dataMask.jobExtent.host_alloc();

	dataMask.jobOrigin[k]=0;
	for (long unsigned i = 0; i < orientation_num; i++)
	{
		dataMask.jobExtent[k]=0;
		int tk=0;
		long int iover_rot = FineProjectionData.iover_rots[i];
		for (long unsigned j = 0; j < translation_num; j++)
		{
			long int iover_trans = iover_transes[j];
			long int ihidden = FineProjectionData.iorientclasses[i] * sp.nr_trans + ihiddens[j];

			if(DIRECT_A2D_ELEM(op.Mcoarse_significant, ipart, ihidden)==1)
			{
				FPW.rot_id[w_base+w] = FineProjectionData.iorientclasses[i] % (sp.nr_dir*sp.nr_psi); 	// where to look for priors etc
				FPW.rot_idx[w_base+w] = i;					// which rot for this significant task
				FPW.trans_idx[w_base+w] = j;					// which trans       - || -
				FPW.ihidden_overs[w_base+w]= (ihidden * nr_over_orient + iover_rot) * nr_over_trans + iover_trans;

				if(tk>=PROJDIFF_CHUNK_SIZE)
				{
					tk=0;             // reset counter
					k++;              // use new element
					dataMask.jobOrigin[k]=w;
					dataMask.jobExtent[k]=0;   // prepare next element for ++ incrementing
				}
				tk++;                 		   // increment limit-checker
				dataMask.jobExtent[k]++;       // increment number of transes this job
				w++;
			}
			else if(tk!=0) 		  // start a new one with the same rotidx - we expect transes to be sequential.
			{
				tk=0;             // reset counter
				k++;              // use new element
				dataMask.jobOrigin[k]=w;
				dataMask.jobExtent[k]=0;   // prepare next element for ++ incrementing
			}
		}
		if(tk>0) // use new element (if tk==0) then we are currently on an element with no signif, so we should continue using this element
		{
			k++;
			dataMask.jobOrigin[k]=w;
			dataMask.jobExtent[k]=0;
		}
	}
	if(dataMask.jobExtent[k]!=0) // if we started putting somehting in last element, then the count is one higher than the index
		k+=1;

	dataMask.setNumberOfJobs(k);
	dataMask.setNumberOfWeights(w);
//	if(dataMask.weightNum>0)
//	{
//		dataMask.jobOrigin.device_alloc();
//		dataMask.jobExtent.device_alloc();
//	}
	return(w);
}

/*
 * This assisting function goes over the weight-array and groups all weights with shared
 * orientations into 'jobs' which are fed into the collect-kenrel, which reduces all translations
 * with computed differences into a reduced object to be back-projected.
 */
int  makeJobsForCollect(IndexedDataArray &FPW, IndexedDataArrayMask &dataMask, unsigned long NewJobNum) // FPW=FinePassWeights
{
	// reset the old (diff2Fine) job-definitions
//	dataMask.jobOrigin.free_host();
//    dataMask.jobOrigin.free_device();
//    dataMask.jobExtent.free_host();
//    dataMask.jobExtent.free_device();
    dataMask.setNumberOfJobs(NewJobNum);
//    dataMask.jobOrigin.host_alloc();
//    dataMask.jobExtent.host_alloc();

	long int jobid=0;
	dataMask.jobOrigin[jobid]=0;
	dataMask.jobExtent[jobid]=1;
	long int crot =FPW.rot_idx[jobid]; // set current rot
	for(long int n=1; n<FPW.rot_idx.size; n++)
	{
		if(FPW.rot_idx[n]==crot)
		{
			dataMask.jobExtent[jobid]++;
		}
		else
		{
			jobid++;
			dataMask.jobExtent[jobid]=1;
			dataMask.jobOrigin[jobid]=n;
			crot=FPW.rot_idx[n];
		}
	}
	dataMask.setNumberOfJobs(jobid+1); // because max index is one less than size
//	dataMask.jobOrigin.put_on_device();
//	dataMask.jobExtent.put_on_device();

	return (jobid+1);
}

/*
 * Splits a designated number of blocks to be run
 * in a cuda-kernel into two components of a dim3.
 */
dim3 splitCudaBlocks(long int block_num, bool doForceEven)
{
	unsigned int orient1, orient2;
	if(block_num>65535)
	{
		orient1 = ceil(sqrt(block_num));
		if(doForceEven)
			orient1 += 	(orient1 % 2);
		orient2 = orient1;
	}
	else
	{
		orient1 = block_num;
		orient2 = 1;
	}
	dim3 block_dim(orient1,orient2);
	return(block_dim);
}

/*
 * Maps weights to a decoupled indexing of translations and orientations
 */
void mapWeights(
		unsigned long orientation_start,
		XFLOAT *mapped_weights,
		unsigned orientation_num,
		unsigned long idxArr_start,
		unsigned long idxArr_end,
		unsigned translation_num,
		XFLOAT *weights,
		long unsigned *rot_idx,
		long unsigned *trans_idx,
		HealpixSampling &sampling,
		long int ipart,
		std::vector< long unsigned > &iover_transes,
		std::vector< long unsigned > &ihiddens,
		std::vector< long unsigned > &iorientclasses,
		std::vector< long unsigned > &iover_rots,
		MultidimArray<XFLOAT> &Mweight,
		unsigned long current_oversampling,
		unsigned long nr_trans)
{

	int nr_over_orient = sampling.oversamplingFactorOrientations(current_oversampling);
	int nr_over_trans =sampling.oversamplingFactorTranslations(current_oversampling);

	for (long unsigned i = 0; i < orientation_num*translation_num; i++)
	{
		mapped_weights[i] = -999.;
	}

	for (long unsigned i = idxArr_start; i < idxArr_end; i++)
	{
		mapped_weights[ (rot_idx[i]-orientation_start) * translation_num + trans_idx[i] ]= weights[i];
	}
}

long unsigned imageTranslation(
		XFLOAT *Fimgs_real,
		XFLOAT *Fimgs_imag,
		XFLOAT *Fimgs_nomask_real,
		XFLOAT *Fimgs_nomask_imag,
		long int itrans_min,
		long int itrans_max,
		int adaptive_oversampling ,
		HealpixSampling &sampling,
		std::vector<double> &oversampled_translations_x,
		std::vector<double> &oversampled_translations_y,
		std::vector<double> &oversampled_translations_z,
		unsigned long nr_oversampled_trans,
		std::vector<MultidimArray<Complex> > &global_fftshifts_ab_current,
		std::vector<MultidimArray<Complex> > &global_fftshifts_ab2_current,
		MultidimArray<Complex > &local_Fimgs_shifted,
		MultidimArray<Complex > &local_Fimgs_shifted_nomask,
		std::vector< long unsigned > &iover_transes,
		std::vector< long unsigned > &itranses,
		std::vector< long unsigned > &ihiddens,
		unsigned image_size)
{

	long unsigned translation_num(0), ihidden(0);

	for (long int itrans = itrans_min, iitrans = 0; itrans <= itrans_max; itrans++, ihidden++)
	{
		sampling.getTranslations(itrans, adaptive_oversampling,
				oversampled_translations_x, oversampled_translations_y, oversampled_translations_z);

		for (long int iover_trans = 0; iover_trans < nr_oversampled_trans; iover_trans++, iitrans++)
		{
			Complex* myAB;
			myAB = (adaptive_oversampling == 0 ) ? global_fftshifts_ab_current[iitrans].data : global_fftshifts_ab2_current[iitrans].data;


			FOR_ALL_DIRECT_ELEMENTS_IN_MULTIDIMARRAY(local_Fimgs_shifted)
			{
				XFLOAT a = (*(myAB + n)).real;
				XFLOAT b = (*(myAB + n)).imag;

				// Fimg_shift
				XFLOAT real = a * (DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted, n)).real
						- b *(DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted, n)).imag;
				XFLOAT imag = a * (DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted, n)).imag
						+ b *(DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted, n)).real;
				Fimgs_real[translation_num * image_size + n] = real;
								Fimgs_imag[translation_num * image_size + n] = imag;

				// Fimg_shift_nomask
				real = a * (DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted_nomask, n)).real
						- b *(DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted_nomask, n)).imag;
				imag = a * (DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted_nomask, n)).imag
						+ b *(DIRECT_MULTIDIM_ELEM(local_Fimgs_shifted_nomask, n)).real;
				Fimgs_nomask_real[translation_num * image_size + n] = real;
				Fimgs_nomask_imag[translation_num * image_size + n] = imag;
			}

			translation_num ++;

			ihiddens.push_back(ihidden);
			itranses.push_back(itrans);
			iover_transes.push_back(iover_trans);
		}
	}

	return translation_num;
}


void generateEulerMatrices(
		XFLOAT padding_factor,
		ProjectionParams &ProjectionData,
		XFLOAT *eulers,
		bool inverse)
{
	double alpha, beta, gamma;
    double ca, sa, cb, sb, cg, sg;
    double cc, cs, sc, ss;

	for (long int i = 0; i < ProjectionData.rots.size(); i++)
	{
	    //TODO In a sense we're doing RAD2DEG just to do DEG2RAD here.
	    //The only place the degree value is actually used is in the metadata assignment.

	    alpha = DEG2RAD(ProjectionData.rots[i]);
	    beta  = DEG2RAD(ProjectionData.tilts[i]);
	    gamma = DEG2RAD(ProjectionData.psis[i]);

	    sincos(alpha, &sa, &ca);
	    sincos(beta,  &sb, &cb);
	    sincos(gamma, &sg, &cg);

	    cc = cb * ca;
	    cs = cb * sa;
	    sc = sb * ca;
	    ss = sb * sa;

		if(inverse)
		{
		    eulers[9 * i + 0] = ( cg * cc - sg * sa) ;// * padding_factor; //00
		    eulers[9 * i + 1] = (-sg * cc - cg * sa) ;// * padding_factor; //10
		    eulers[9 * i + 2] = ( sc )               ;// * padding_factor; //20
		    eulers[9 * i + 3] = ( cg * cs + sg * ca) ;// * padding_factor; //01
		    eulers[9 * i + 4] = (-sg * cs + cg * ca) ;// * padding_factor; //11
		    eulers[9 * i + 5] = ( ss )               ;// * padding_factor; //21
		    eulers[9 * i + 6] = (-cg * sb )          ;// * padding_factor; //02
		    eulers[9 * i + 7] = ( sg * sb )          ;// * padding_factor; //12
		    eulers[9 * i + 8] = ( cb )               ;// * padding_factor; //22
		}
		else
		{
		    eulers[9 * i + 0] = ( cg * cc - sg * sa) ;// * padding_factor; //00
		    eulers[9 * i + 1] = ( cg * cs + sg * ca) ;// * padding_factor; //01
		    eulers[9 * i + 2] = (-cg * sb )          ;// * padding_factor; //02
		    eulers[9 * i + 3] = (-sg * cc - cg * sa) ;// * padding_factor; //10
		    eulers[9 * i + 4] = (-sg * cs + cg * ca) ;// * padding_factor; //11
		    eulers[9 * i + 5] = ( sg * sb )          ;// * padding_factor; //12
		    eulers[9 * i + 6] = ( sc )               ;// * padding_factor; //20
		    eulers[9 * i + 7] = ( ss )               ;// * padding_factor; //21
		    eulers[9 * i + 8] = ( cb )               ;// * padding_factor; //22
		}
	}
}


long unsigned generateProjectionSetup(
		OptimisationParamters &op,
		SamplingParameters &sp,
		MlOptimiser *baseMLO,
		bool coarse,
		unsigned iclass,
		ProjectionParams &ProjectionData)
// FIXME : For coarse iteration this is **SLOW**    HERE ARE SOME NOTES FOR PARALLELIZING IT (GPU OFFLOAD):
/*
 *    Since it is based on push_back, parallelizing sould be fine given som atomic opreation appends,
 *    what takes time is looping through all this. The job-splitting in collect2jobs-preproccesing and
 *    divideOrientationsIntoBlockjobs() relies on chunks of shared orientations being adjacent in
 *    ProjectionData.rot_id (and thus also .rot_idx), but does not care which order those chunks appear
 *    in. So as long as a parallelilsm and "atomic push_back" is organised to use an orientation as a
 *    minimum unit, the job-splitting should be fine with the output.
 */
{
	//Local variables
	std::vector< double > oversampled_rot, oversampled_tilt, oversampled_psi;
	long int orientation_num = 0;

	for (long int idir = sp.idir_min, iorient = 0; idir <= sp.idir_max; idir++)
	{
		for (long int ipsi = sp.ipsi_min, ipart = 0; ipsi <= sp.ipsi_max; ipsi++, iorient++)
		{
			long int iorientclass = iclass * sp.nr_dir * sp.nr_psi + iorient;

			// Get prior for this direction and skip calculation if prior==0
			double pdf_orientation;
			if (baseMLO->do_skip_align || baseMLO->do_skip_rotate)
			{
				pdf_orientation = baseMLO->mymodel.pdf_class[iclass];
			}
			else if (baseMLO->mymodel.orientational_prior_mode == NOPRIOR)
			{
				pdf_orientation = DIRECT_MULTIDIM_ELEM(baseMLO->mymodel.pdf_direction[iclass], idir);
			}
			else
			{
				pdf_orientation = op.directions_prior[idir] * op.psi_prior[ipsi];
			}
			// In the first pass, always proceed
			// In the second pass, check whether one of the translations for this orientation of any of the particles had a significant weight in the first pass
			// if so, proceed with projecting the reference in that direction

			bool do_proceed = coarse ? true :
					baseMLO->isSignificantAnyParticleAnyTranslation(iorientclass, sp.itrans_min, sp.itrans_max, op.Mcoarse_significant);

			if (do_proceed && pdf_orientation > 0.)
			{
				// Now get the oversampled (rot, tilt, psi) triplets
				// This will be only the original (rot,tilt,psi) triplet in the first pass (sp.current_oversampling==0)
				baseMLO->sampling.getOrientations(idir, ipsi, sp.current_oversampling, oversampled_rot, oversampled_tilt, oversampled_psi,
						op.pointer_dir_nonzeroprior, op.directions_prior, op.pointer_psi_nonzeroprior, op.psi_prior);

				// Loop over all oversampled orientations (only a single one in the first pass)
				for (long int iover_rot = 0; iover_rot < sp.nr_oversampled_rot; iover_rot++, ipart++)
				{
					ProjectionData.pushBackAll(	(long unsigned)iclass,
												oversampled_rot[iover_rot],
											    oversampled_tilt[iover_rot],
											    oversampled_psi[iover_rot],
											    iorientclass,
											    iover_rot 					);
					orientation_num ++;
				}
			}
		}
	}
	ProjectionData.orientation_num[iclass]=orientation_num;
	return orientation_num;
}

void runWavgKernel(
		CudaProjectorKernel &projector,
		XFLOAT *eulers,
		XFLOAT *Fimgs_real,
		XFLOAT *Fimgs_imag,
		XFLOAT *Fimgs_nomask_real,
		XFLOAT *Fimgs_nomask_imag,
		XFLOAT *sorted_weights,
		XFLOAT *ctfs,
		XFLOAT *Minvsigma2s,
		XFLOAT *wdiff2s_parts,
		XFLOAT *wavgs_real,
		XFLOAT *wavgs_imag,
		XFLOAT *Fweights,
		OptimisationParamters &op,
		MlOptimiser *baseMLO,
		long unsigned orientation_num,
		long unsigned translation_num,
		unsigned image_size,
		long int ipart,
		int group_id,
		int exp_iclass,
		cudaStream_t stream)
{
	//We only want as many blocks as there are chunks of orientations to be treated
	//within the same block (this is done to reduce memory loads in the kernel).
	unsigned orientation_chunks = orientation_num;//ceil((float)orientation_num/(float)REF_GROUP_SIZE);
	CUDA_CPU_TIC("splitblocks");
	dim3 block_dim = splitCudaBlocks(orientation_chunks,false);
	CUDA_CPU_TOC("splitblocks");

	CUDA_CPU_TIC("cuda_kernel_wavg");
	CUDA_GPU_TIC("cuda_kernel_wavg");

	//cudaFuncSetCacheConfig(cuda_kernel_wavg_fast, cudaFuncCachePreferShared);

	if(projector.mdlZ!=0)
		cuda_kernel_wavg<true><<<block_dim,BLOCK_SIZE,0,stream>>>(
			eulers,
			projector,
			image_size,
			orientation_num,
			Fimgs_real,
			Fimgs_imag,
			Fimgs_nomask_real,
			Fimgs_nomask_imag,
			sorted_weights,
			ctfs,
			Minvsigma2s,
			wdiff2s_parts,
			wavgs_real,
			wavgs_imag,
			Fweights,
			translation_num,
			(XFLOAT) op.sum_weight[ipart],
			(XFLOAT) op.significant_weight[ipart],
			baseMLO->refs_are_ctf_corrected
			);
	else
		cuda_kernel_wavg<false><<<block_dim,BLOCK_SIZE,0,stream>>>(
			eulers,
			projector,
			image_size,
			orientation_num,
			Fimgs_real,
			Fimgs_imag,
			Fimgs_nomask_real,
			Fimgs_nomask_imag,
			sorted_weights,
			ctfs,
			Minvsigma2s,
			wdiff2s_parts,
			wavgs_real,
			wavgs_imag,
			Fweights,
			translation_num,
			(XFLOAT) op.sum_weight[ipart],
			(XFLOAT) op.significant_weight[ipart],
			baseMLO->refs_are_ctf_corrected
			);

	CUDA_GPU_TAC("cuda_kernel_wavg");
	CUDA_CPU_TOC("cuda_kernel_wavg");
}


void runDiff2KernelCoarse(
		CudaProjectorKernel &projector,
		XFLOAT *gpuMinvsigma2,
		XFLOAT *Fimgs_real,
		XFLOAT *Fimgs_imag,
		XFLOAT *d_eulers,
		XFLOAT *diff2s,
		OptimisationParamters &op,
		MlOptimiser *baseMLO,
		long unsigned orientation_num,
		long unsigned translation_num,
		unsigned image_size,
		int ipart,
		int group_id,
		int exp_iclass)
{

	CUDA_GPU_TIC("runProjAndDifferenceKernelCoarse");

	if(projector.mdlZ!=0)
		cuda_kernel_diff2_coarse<true><<<orientation_num,BLOCK_SIZE,translation_num*BLOCK_SIZE*sizeof(XFLOAT)>>>(
			d_eulers,
			Fimgs_real,
			Fimgs_imag,
			projector,
			gpuMinvsigma2,
			diff2s,
			translation_num,
			image_size,
			op.highres_Xi2_imgs[ipart] / 2.);
	else
		cuda_kernel_diff2_coarse<false><<<orientation_num,BLOCK_SIZE,translation_num*BLOCK_SIZE*sizeof(XFLOAT)>>>(
			d_eulers,
			Fimgs_real,
			Fimgs_imag,
			projector,
			gpuMinvsigma2,
			diff2s,
			translation_num,
			image_size,
			op.highres_Xi2_imgs[ipart] / 2.);

	CUDA_GPU_TAC("runProjAndDifferenceKernelCoarse");
}


void runDiff2KernelFine(
		CudaProjectorKernel &projector,
		XFLOAT *gpuMinvsigma2,
		XFLOAT *Fimgs_real,
		XFLOAT *Fimgs_imag,
		XFLOAT *eulers,
		long unsigned *rot_id,
		long unsigned *rot_idx,
		long unsigned *trans_idx,
		long unsigned *job_idx,
		long unsigned *job_num,
		XFLOAT *diff2s,
		OptimisationParamters &op,
		MlOptimiser *baseMLO,
		long unsigned orientation_num,
		long unsigned translation_num,
		long unsigned significant_num,
		unsigned image_size,
		int ipart,
		long unsigned job_num_count)
{
    dim3 block_dim = splitCudaBlocks(job_num_count,false);

	if(projector.mdlZ!=0)
		cuda_kernel_diff2_fine<true><<<block_dim,BLOCK_SIZE>>>(
			eulers,
			Fimgs_real,
			Fimgs_imag,
			projector,
			gpuMinvsigma2,
			diff2s,
			image_size,
			op.highres_Xi2_imgs[ipart] / 2.,
			orientation_num,
			translation_num,
			job_num_count, //significant_num,
			rot_idx,
			trans_idx,
			job_idx,
			job_num);
	else
		cuda_kernel_diff2_fine<false><<<block_dim,BLOCK_SIZE>>>(
			eulers,
			Fimgs_real,
			Fimgs_imag,
			projector,
			gpuMinvsigma2,
			diff2s,
			image_size,
			op.highres_Xi2_imgs[ipart] / 2.,
			orientation_num,
			translation_num,
			job_num_count, //significant_num,
			rot_idx,
			trans_idx,
			job_idx,
			job_num);
}