/******************************************************************************
 * Copyright 2010 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 ******************************************************************************/

/******************************************************************************
 * Level-grid BFS implementation
 ******************************************************************************/

#pragma once

#include <bfs_base.cu>

#include <b40c/util/spine.cuh>
#include <b40c/util/global_barrier.cuh>
#include <b40c/bfs/problem_type.cuh>
#include <b40c/bfs/single_grid/problem_config.cuh>
#include <b40c/bfs/single_grid/sweep_kernel.cuh>

namespace b40c {
namespace bfs {


/**
 * Single-grid breadth-first-search enactor.
 */
class SingleGridBfsEnactor : public BaseBfsEnactor
{

protected:

	/**
	 * Temporary device storage needed for reducing partials produced
	 * by separate CTAs
	 */
	util::Spine spine;

	/**
	 * Mechanism for implementing software global barriers from within
	 * a single grid invocation
	 */
	util::GlobalBarrierLifetime global_barrier;

public: 	
	
	/**
	 * Constructor
	 */
	SingleGridBfsEnactor(bool DEBUG = false) : BaseBfsEnactor(DEBUG) {}


    /**
     * Obtain statistics about the last BFS search enacted 
     */
    void GetStatistics(
    	int &total_queued, 
    	int &passes, 
    	double &avg_barrier_wait)		// total time spent waiting in barriers in ms (threadblock average)
    {
    	total_queued = 0;
    	passes = 0;
    	avg_barrier_wait = 0;
    }
    
	/**
	 * Enacts a breadth-first-search on the specified graph problem.
	 *
	 * @return cudaSuccess on success, error enumeration otherwise
	 */
    template <typename BfsCsrProblem>
	cudaError_t EnactSearch(
		BfsCsrProblem 						&bfs_problem,
		typename BfsCsrProblem::VertexId 	src,
		int 								max_grid_size = 0)
	{
		cudaError_t retval = cudaSuccess;
		typedef typename BfsCsrProblem::SizeT SizeT;

		// Compaction tuning configuration
		typedef single_grid::ProblemConfig<

			typename BfsCsrProblem::ProblemType,
			200,					// CUDA_ARCH
			8,						// MAX_CTA_OCCUPANCY
			7,						// LOG_THREADS
			util::io::ld::cg,
			util::io::st::cg,
			9,						// SCHEDULE_GRANULARITY

			// BFS expand
			0,						// LOG_LOAD_VEC_SIZE
			0,						// LOG_LOADS_PER_TILE
			5,						// LOG_RAKING_THREADS
			util::io::ld::cg,		// QUEUE_READ_MODIFIER,
			util::io::ld::NONE,		// COLUMN_READ_MODIFIER,
			util::io::ld::cg,		// ROW_OFFSET_ALIGNED_READ_MODIFIER,
			util::io::ld::cg,		// ROW_OFFSET_UNALIGNED_READ_MODIFIER,
			util::io::st::cg,		// QUEUE_WRITE_MODIFIER,
			true,					// WORK_STEALING
			6,						// EXPAND_LOG_SCHEDULE_GRANULARITY

			// Compact upsweep
			0,						// LOG_LOAD_VEC_SIZE
			0,						// LOG_LOADS_PER_TILE

			// Compact spine
			0,						// LOG_LOAD_VEC_SIZE
			0,						// LOG_LOADS_PER_TILE
			5,						// LOG_RAKING_THREADS

			// Compact downsweep
			1,						// LOG_LOAD_VEC_SIZE
			1,						// LOG_LOADS_PER_TILE
			5> 						// LOG_RAKING_THREADS
				ProblemConfig;



		int occupancy = ProblemConfig::CTA_OCCUPANCY;
		int grid_size = MaxGridSize(occupancy, max_grid_size);

		printf("DEBUG: BFS occupancy %d, grid size %d\n",
			occupancy, grid_size);

		// Make sure spine and barriers are initialized
		int spine_elements = grid_size;
		if (retval = spine.Setup<SizeT>(grid_size, spine_elements)) exit(1);
		if (retval = global_barrier.Setup(grid_size)) (exit(1));

		single_grid::SweepKernel<ProblemConfig><<<grid_size, ProblemConfig::THREADS>>>(
			src,

			bfs_problem.d_expand_queue,
			bfs_problem.d_expand_parent_queue,
			bfs_problem.d_compact_queue,
			bfs_problem.d_compact_parent_queue,

			bfs_problem.d_column_indices,
			bfs_problem.d_row_offsets,
			bfs_problem.d_source_path,
			bfs_problem.d_collision_cache,
			bfs_problem.d_keep,
			(SizeT *) this->spine(),

			this->work_progress,
			this->global_barrier,
			spine_elements	);

		if (retval = util::B40CPerror(cudaThreadSynchronize(),
			"SweepKernel failed", __FILE__, __LINE__)) exit(1);

		return retval;
	}
    
};




} // namespace bfs
} // namespace b40c
