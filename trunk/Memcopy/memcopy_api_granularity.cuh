/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
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
 ******************************************************************************/

/******************************************************************************
 *  Memcopy Granularity Configuration
 ******************************************************************************/

#pragma once

#include "b40c_cuda_properties.cuh"
#include "b40c_kernel_data_movement.cuh"

namespace b40c {
namespace memcopy {


/**
 * Memcopy granularity configuration.  This C++ type encapsulates our
 * kernel-tuning parameters (they are reflected via the static fields).
 *
 * The kernels are specialized for problem-type, SM-version, etc. by declaring
 * them with different performance-tuned parameterizations of this type.  By
 * incorporating this type into the kernel code itself, we guide the compiler in
 * expanding/unrolling the kernel code for specific architectures and problem
 * types.
 */
template <
	typename _T,
	int _LOG_SCHEDULE_GRANULARITY,
	int _CTA_OCCUPANCY,
	int _LOG_THREADS,
	int _LOG_LOAD_VEC_SIZE,
	int _LOG_LOADS_PER_TILE,
	CacheModifier _CACHE_MODIFIER,
	bool _WORK_STEALING>
struct MemcopyConfig
{
	typedef _T									T;
	typedef size_t								SizeT;
	static const int LOG_SCHEDULE_GRANULARITY	= _LOG_SCHEDULE_GRANULARITY;
	static const int CTA_OCCUPANCY  			= _CTA_OCCUPANCY;
	static const int LOG_THREADS 				= _LOG_THREADS;
	static const int LOG_LOAD_VEC_SIZE  		= _LOG_LOAD_VEC_SIZE;
	static const int LOG_LOADS_PER_TILE 		= _LOG_LOADS_PER_TILE;
	static const CacheModifier CACHE_MODIFIER 	= _CACHE_MODIFIER;
	static const bool WORK_STEALING				= _WORK_STEALING;
};
		

}// namespace memcopy
}// namespace b40c
