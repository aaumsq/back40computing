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
 * Abstract tile-processing functionality for partitioning downsweep scan
 * kernels
 ******************************************************************************/

#pragma once

#include <b40c/util/cuda_properties.cuh>
#include <b40c/util/basic_utils.cuh>
#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>
#include <b40c/util/io/load_tile.cuh>
#include <b40c/util/io/scatter_tile.cuh>
#include <b40c/util/reduction/serial_reduce.cuh>
#include <b40c/util/scan/serial_scan.cuh>
#include <b40c/util/scan/warp_scan.cuh>
#include <b40c/util/device_intrinsics.cuh>
#include <b40c/util/soa_tuple.cuh>
#include <b40c/util/scan/soa/cooperative_soa_scan.cuh>

namespace b40c {
namespace partition {
namespace downsweep {


/**
 * Tile
 *
 * Abstract class
 */
template <
	typename KernelPolicy,
	typename DerivedTile>
struct Tile
{
	//---------------------------------------------------------------------
	// Typedefs and Constants
	//---------------------------------------------------------------------

	typedef typename KernelPolicy::KeyType 					KeyType;
	typedef typename KernelPolicy::ValueType 				ValueType;
	typedef typename KernelPolicy::SizeT 					SizeT;

	typedef DerivedTile Dispatch;

	enum {
		LOAD_VEC_SIZE 				= KernelPolicy::LOAD_VEC_SIZE,
		LOADS_PER_CYCLE 			= KernelPolicy::LOADS_PER_CYCLE,
		CYCLES_PER_TILE 			= KernelPolicy::CYCLES_PER_TILE,
		TILE_ELEMENTS_PER_THREAD 	= KernelPolicy::TILE_ELEMENTS_PER_THREAD,
		SCAN_LANES_PER_CYCLE		= KernelPolicy::SCAN_LANES_PER_CYCLE,

		LANE_ROWS_PER_LOAD 			= KernelPolicy::ByteGrid::ROWS_PER_LANE / KernelPolicy::LOADS_PER_CYCLE,
		LANE_STRIDE_PER_LOAD 		= KernelPolicy::ByteGrid::PADDED_PARTIALS_PER_ROW * LANE_ROWS_PER_LOAD,

		INVALID_BIN					= -1,

		LOG_WARPSCAN_THREADS		= B40C_LOG_WARP_THREADS(CUDA_ARCH),
		WARPSCAN_THREADS 			= 1 << LOG_WARPSCAN_THREADS,

	};

	//---------------------------------------------------------------------
	// Members
	//---------------------------------------------------------------------


	// The keys (and values) this thread will read this cycle
	KeyType 	keys[CYCLES_PER_TILE][LOADS_PER_CYCLE][LOAD_VEC_SIZE];
	ValueType 	values[TILE_ELEMENTS_PER_THREAD];

	// For each load:
	// 		counts_nibbles contains the bin counts within nibbles ordered right to left
	// 		bins_nibbles contains the bin for each key within nibbles ordered right to left
	// 		load_prefix_bytes contains the exclusive scan for each key within nibbles ordered right to left

	int 		bins_nibbles[CYCLES_PER_TILE][LOADS_PER_CYCLE];

	int 		counts_nibbles[CYCLES_PER_TILE][LOADS_PER_CYCLE];
	int			counts_bytes0[CYCLES_PER_TILE][LOADS_PER_CYCLE];
	int			counts_bytes1[CYCLES_PER_TILE][LOADS_PER_CYCLE];

	int 		load_prefix_bytes0[CYCLES_PER_TILE][LOADS_PER_CYCLE];
	int 		load_prefix_bytes1[CYCLES_PER_TILE][LOADS_PER_CYCLE];

	int 		local_ranks[CYCLES_PER_TILE][LOADS_PER_CYCLE][LOAD_VEC_SIZE];		// The local rank of each key
	SizeT 		scatter_offsets[CYCLES_PER_TILE][LOADS_PER_CYCLE][LOAD_VEC_SIZE];	// The global rank of each key


	//---------------------------------------------------------------------
	// Abstract Interface
	//---------------------------------------------------------------------

	/**
	 * Returns whether or not the key is valid.
	 *
	 * To be overloaded.
	 */
	template <typename Cta>
	__device__ __forceinline__ SizeT ValidElements(Cta *cta, const SizeT &guarded_elements)
	{
		return guarded_elements;
	}

	/**
	 * Returns the bin into which the specified key is to be placed.
	 *
	 * To be overloaded
	 */
	template <typename Cta>
	__device__ __forceinline__ int DecodeBin(KeyType key, Cta *cta);


	/**
	 * Returns whether or not the key is valid.
	 *
	 * To be overloaded.
	 */
	template <int CYCLE, int LOAD, int VEC>
	__device__ __forceinline__ bool IsValid();


	/**
	 * Loads keys into the tile
	 *
	 * Can be overloaded.
	 */
	template <typename Cta>
	__device__ __forceinline__ void LoadKeys(
		Cta *cta,
		SizeT cta_offset,
		const SizeT &guarded_elements)
	{
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS,
			KernelPolicy::READ_MODIFIER,
			KernelPolicy::CHECK_ALIGNMENT>::LoadValid(
				(KeyType (*)[KernelPolicy::LOAD_VEC_SIZE]) keys,
				cta->d_in_keys,
				cta_offset,
				guarded_elements);
	}


	/**
	 * Scatter keys from the tile
	 *
	 * Can be overloaded.
	 */
	template <typename Cta>
	__device__ __forceinline__ void ScatterKeys(
		Cta *cta,
		const SizeT &guarded_elements)
	{
		// Scatter keys to global bin partitions
		util::io::ScatterTile<
			KernelPolicy::LOG_TILE_ELEMENTS_PER_THREAD,
			0,
			KernelPolicy::THREADS,
			KernelPolicy::WRITE_MODIFIER>::Scatter(
				cta->d_out_keys,
				(KeyType (*)[1]) keys,
				(SizeT (*)[1]) scatter_offsets,
				guarded_elements);
	}


	/**
	 * Loads values into the tile
	 *
	 * Can be overloaded.
	 */
	template <typename Cta>
	__device__ __forceinline__ void LoadValues(
		Cta *cta,
		SizeT cta_offset,
		const SizeT &guarded_elements)
	{
		// Read values
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS,
			KernelPolicy::READ_MODIFIER,
			KernelPolicy::CHECK_ALIGNMENT>::LoadValid(
				(ValueType (*)[KernelPolicy::LOAD_VEC_SIZE]) values,
				cta->d_in_values,
				cta_offset,
				guarded_elements);
	}


	/**
	 * Scatter values from the tile
	 *
	 * Can be overloaded.
	 */
	template <typename Cta>
	__device__ __forceinline__ void ScatterValues(
		Cta *cta,
		const SizeT &guarded_elements)
	{
		// Scatter values to global bin partitions
		util::io::ScatterTile<
			KernelPolicy::LOG_TILE_ELEMENTS_PER_THREAD,
			0,
			KernelPolicy::THREADS,
			KernelPolicy::WRITE_MODIFIER>::Scatter(
				cta->d_out_values,
				(ValueType (*)[1]) values,
				(SizeT (*)[1]) scatter_offsets,
				guarded_elements);
	}


	//---------------------------------------------------------------------
	// Cycle Methods
	//---------------------------------------------------------------------


	/**
	 * DecodeKeys
	 */
	template <int CYCLE, int LOAD, int VEC, typename Cta>
	__device__ __forceinline__ void DecodeKeys(Cta *cta)
	{
		Dispatch *dispatch = (Dispatch *) this;

		// Decode the bin for this key
		int bin;
		if (dispatch->template IsValid<CYCLE, LOAD, VEC>()) {
			bin = dispatch->DecodeBin(keys[CYCLE][LOAD][VEC], cta);
		} else {
			bin = INVALID_BIN;
		}

		const int LOG_BITS_PER_NIBBLE = 2;
		const int BITS_PER_NIBBLE = 1 << LOG_BITS_PER_NIBBLE;

		int shift = bin << LOG_BITS_PER_NIBBLE;

		// Initialize exclusive scan bytes
		if (VEC == 0) {
			load_prefix_bytes0[CYCLE][LOAD] = 0;

		} else if (VEC == 4) {
			load_prefix_bytes1[CYCLE][LOAD] = 0;

		} else {
			int prev_counts_nibbles = counts_nibbles[CYCLE][LOAD] >> shift;
			if (VEC < 4) {
				util::BFI(
					load_prefix_bytes0[CYCLE][LOAD],
					load_prefix_bytes0[CYCLE][LOAD],
					prev_counts_nibbles,
					8 * VEC,
					BITS_PER_NIBBLE);
			} else {
				util::BFI(
					load_prefix_bytes1[CYCLE][LOAD],
					load_prefix_bytes1[CYCLE][LOAD],
					prev_counts_nibbles,
					8 * (VEC - 4),
					BITS_PER_NIBBLE);
			}
		}

		// Initialize counts and bins nibbles
		if (VEC == 0) {
			counts_nibbles[CYCLE][LOAD] = 1 << shift;
			bins_nibbles[CYCLE][LOAD] = bin;

		} else {
			util::BFI(
				bins_nibbles[CYCLE][LOAD],
				bins_nibbles[CYCLE][LOAD],
				bin,
				4 * VEC,
				4);

			util::SHL_ADD(
				counts_nibbles[CYCLE][LOAD],
				1,
				shift,
				counts_nibbles[CYCLE][LOAD]);
		}
	}


	/**
	 * ExtractRanks
	 */
	template <int CYCLE, int LOAD, int VEC, typename Cta>
	__device__ __forceinline__ void ExtractRanks(Cta *cta)
	{
		Dispatch *dispatch = (Dispatch *) this;
		if (dispatch->template IsValid<CYCLE, LOAD, VEC>()) {

			if (VEC == 0) {

				const int LANE_OFFSET = LOAD * LANE_STRIDE_PER_LOAD;

				// Extract prefix bytes from bytes raking grid
				counts_bytes0[CYCLE][LOAD] = cta->byte_grid_details.lane_partial[0][LANE_OFFSET];
				counts_bytes1[CYCLE][LOAD] = cta->byte_grid_details.lane_partial[1][LANE_OFFSET];

				// Decode prefix bytes for first four keys
				load_prefix_bytes0[CYCLE][LOAD] += util::PRMT(
					counts_bytes0[CYCLE][LOAD],
					counts_bytes1[CYCLE][LOAD],
					bins_nibbles[CYCLE][LOAD]);

				if (LOAD_VEC_SIZE >= 4) {
					// Decode prefix bytes for second four keys
					load_prefix_bytes1[CYCLE][LOAD] += util::PRMT(
						counts_bytes0[CYCLE][LOAD],
						counts_bytes1[CYCLE][LOAD],
						bins_nibbles[CYCLE][LOAD] >> 16);
				}
			}

			// Determine prefix from nibble- and byte-packed predecessors in the raking segment
			int raking_seg_prefix;
			if (VEC < 4) {
				raking_seg_prefix = util::BFE(load_prefix_bytes0[CYCLE][LOAD], VEC * 8, 8);
			} else {
				raking_seg_prefix = util::BFE(load_prefix_bytes1[CYCLE][LOAD], (VEC - 4) * 8, 8);
			}

			// Determine the prefix from the short-packed warpscans

			int byte_raking_segment =
				(threadIdx.x >> KernelPolicy::ByteGrid::LOG_PARTIALS_PER_SEG) +
				((KernelPolicy::THREADS * LOAD) >> KernelPolicy::ByteGrid::LOG_PARTIALS_PER_SEG);

			int lane = util::BFE(bins_nibbles[CYCLE][LOAD], (VEC * 4) + 2, 2);
			int half = util::BFE(bins_nibbles[CYCLE][LOAD], (VEC * 4), 1);
			int quarter = util::BFE(bins_nibbles[CYCLE][LOAD], (VEC * 4) + 1, 1);
			int row = (lane << 1) + half;

			int warpscan_prefix = cta->smem_storage.short_prefixes_b[row][byte_raking_segment][quarter];

			local_ranks[CYCLE][LOAD][VEC] = raking_seg_prefix + warpscan_prefix;

/*
			printf("\ttid(%u), load(%u), vec(%u), "
				"key(%u):\t,"
				"raking_seg_prefix(%u), "
				"byte_raking_segment(%u), "
				"lane(%u), "
				"half(%u), "
				"row(%u), "
				"quarter(%u), "
				"warpscan_prefix(%u), "
				"local_ranks(%u), "
				"\n",
				threadIdx.x, LOAD, VEC,
				keys[CYCLE][LOAD][VEC],
				raking_seg_prefix,
				byte_raking_segment,
				lane,
				half,
				row,
				quarter,
				warpscan_prefix,
				local_ranks[CYCLE][LOAD][VEC]);
*/
		} else {
			// Put invalid keys just after the end of the valid swap exchange.
			local_ranks[CYCLE][LOAD][VEC] = KernelPolicy::TILE_ELEMENTS;
		}

	}



	//---------------------------------------------------------------------
	// IterateCycleElements Structures
	//---------------------------------------------------------------------

	/**
	 * Iterate next vector element
	 */
	template <int CYCLE, int LOAD, int VEC, int dummy = 0>
	struct IterateCycleElements
	{
		// DecodeKeys
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void DecodeKeys(Cta *cta, Tile *tile)
		{
			tile->DecodeKeys<CYCLE, LOAD, VEC>(cta);
			IterateCycleElements<CYCLE, LOAD, VEC + 1>::DecodeKeys(cta, tile);
		}

		// ExtractRanks
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void ExtractRanks(Cta *cta, Tile *tile)
		{
			tile->ExtractRanks<CYCLE, LOAD, VEC>(cta);
			IterateCycleElements<CYCLE, LOAD, VEC + 1>::ExtractRanks(cta, tile);
		}
	};


	/**
	 * IterateCycleElements next load
	 */
	template <int CYCLE, int LOAD, int dummy>
	struct IterateCycleElements<CYCLE, LOAD, LOAD_VEC_SIZE, dummy>
	{
		// DecodeKeys
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void DecodeKeys(Cta *cta, Tile *tile)
		{
			// Expand nibble-packed counts into pair of byte-packed counts
			util::NibblesToBytes(
				tile->counts_bytes0[CYCLE][LOAD],
				tile->counts_bytes1[CYCLE][LOAD],
				tile->counts_nibbles[CYCLE][LOAD]);

			const int LANE_OFFSET = LOAD * LANE_STRIDE_PER_LOAD;

			// Place keys into raking grid
			cta->byte_grid_details.lane_partial[0][LANE_OFFSET] = tile->counts_bytes0[CYCLE][LOAD];
			cta->byte_grid_details.lane_partial[1][LANE_OFFSET] = tile->counts_bytes1[CYCLE][LOAD];
/*
			printf("Tid %u cycle %u load %u:\t,"
				"load_prefix_bytes0(%08x), "
				"load_prefix_bytes1(%08x), "
				"bins_nibbles(%08x), "
				"counts_bytes0(%08x), "
				"counts_bytes1(%08x), "
				"\n",
				threadIdx.x, CYCLE, LOAD,
				tile->load_prefix_bytes0[CYCLE][LOAD],
				tile->load_prefix_bytes1[CYCLE][LOAD],
				tile->bins_nibbles[CYCLE][LOAD],
				tile->counts_bytes0[CYCLE][LOAD],
				tile->counts_bytes1[CYCLE][LOAD]);
*/
			IterateCycleElements<CYCLE, LOAD + 1, 0>::DecodeKeys(cta, tile);
		}

		// ExtractRanks
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void ExtractRanks(Cta *cta, Tile *tile)
		{
			IterateCycleElements<CYCLE, LOAD + 1, 0>::ExtractRanks(cta, tile);
		}

	};

	/**
	 * Terminate iteration
	 */
	template <int CYCLE, int dummy>
	struct IterateCycleElements<CYCLE, LOADS_PER_CYCLE, 0, dummy>
	{
		// DecodeKeys
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void DecodeKeys(Cta *cta, Tile *tile) {}

		// ExtractRanks
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void ExtractRanks(Cta *cta, Tile *tile) {}
	};



	//---------------------------------------------------------------------
	// Tile Internal Methods
	//---------------------------------------------------------------------


	/**
	 * SOA scan operator (independent addition)
	 */
	struct SoaSumOp
	{
		enum {
			IDENTITY_STRIDES = true,			// There is an "identity" region of warpscan storage exists for strides to index into
		};

		// Tuple of partial-flag type
		typedef util::Tuple<int, int> TileTuple;

		// Scan operator
		__device__ __forceinline__ TileTuple operator()(
			const TileTuple &first,
			const TileTuple &second)
		{
			return TileTuple(first.t0 + second.t0, first.t1 + second.t1);
		}

		// Identity operator
		__device__ __forceinline__ TileTuple operator()()
		{
			return TileTuple(0,0);
		}

		template <typename WarpscanT>
		static __device__ __forceinline__ TileTuple WarpScanInclusive(
			TileTuple &total,
			TileTuple partial,
			WarpscanT warpscan_low,
			WarpscanT warpscan_high)
		{
			// SOA type of warpscan storage
			typedef util::Tuple<WarpscanT, WarpscanT> WarpscanSoa;

			WarpscanSoa warpscan_soa(warpscan_low, warpscan_high);
			SoaSumOp scan_op;

			// Exclusive warp scan, get total
			TileTuple inclusive_partial = util::scan::soa::WarpSoaScan<
				LOG_WARPSCAN_THREADS,
				false>::Scan(
					partial,
					total,
					warpscan_soa,
					scan_op);

			return inclusive_partial;
		}
	};


	/**
	 * Scan Cycle
	 */
	template <int CYCLE, typename Cta>
	__device__ __forceinline__ void ScanCycle(Cta *cta)
	{
		typedef typename SoaSumOp::TileTuple TileTuple;

		Dispatch *dispatch = (Dispatch*) this;

		// Decode bins and place keys into grid
		IterateCycleElements<CYCLE, 0, 0>::DecodeKeys(cta, dispatch);

		__syncthreads();

		// Use our raking threads to, in aggregate, scan the composite counter lanes
		if (threadIdx.x < KernelPolicy::ByteGrid::RAKING_THREADS) {
/*
			if (threadIdx.x == 0) {
				printf("ByteGrid:\n");
				KernelPolicy::ByteGrid::Print();
				printf("\n");
			}
*/
			// Upsweep rake
			int partial_bytes = util::scan::SerialScan<KernelPolicy::ByteGrid::PARTIALS_PER_SEG>::Invoke(
				cta->byte_grid_details.raking_segment,
				0);

			// Unpack byte-packed partial sum into short-packed partial sums
			TileTuple partial_shorts(
				util::PRMT(partial_bytes, 0, 0x4240),
				util::PRMT(partial_bytes, 0, 0x4341));
/*
			printf("\t\tRaking thread %d reduced partial(%08x), extracted to ((%u,%u),(%u,%u))\n",
				threadIdx.x,
				partial_bytes,
				partial_shorts.t0 >> 16, partial_shorts.t0 & 0x0000ffff,
				partial_shorts.t1 >> 16, partial_shorts.t1 & 0x0000ffff);
*/
			// Perform structure-of-arrays warpscan

			TileTuple total;
			TileTuple inclusive_partial = SoaSumOp::WarpScanInclusive(
				total,
				partial_shorts,
				cta->smem_storage.warpscan_low,
				cta->smem_storage.warpscan_high);
/*
			printf("Raking tid %d with inclusive_partial((%u,%u),(%u,%u)) and sums((%u,%u),(%u,%u))\n",
				threadIdx.x,
				inclusive_partial.t0 >> 16, inclusive_partial.t0 & 0x0000ffff,
				inclusive_partial.t1 >> 16, inclusive_partial.t1 & 0x0000ffff,
				total.t0 >> 16, total.t0 & 0x0000ffff,
				total.t1 >> 16, total.t1 & 0x0000ffff);
*/
			// Propagate the bottom total halves into the top inclusive partial halves
			inclusive_partial.t0 = util::SHL_ADD_C(total.t0, 16, inclusive_partial.t0);
			inclusive_partial.t1 = util::SHL_ADD_C(total.t1, 16, inclusive_partial.t1);


			// Take the bottom half of the lower inclusive partial
			// and add it into the top half (top half now contains sum of both halves of total.t0)
			int lower_addend = util::SHL_ADD_C(total.t0, 16, total.t0);

			// Duplicate the top half
			lower_addend = util::PRMT(lower_addend, 0, 0x3232);

			// Add it into the upper inclusive partial
			inclusive_partial.t1 += lower_addend;

			// Create exclusive partial
			TileTuple exclusive_partial(
				inclusive_partial.t0 - partial_shorts.t0,
				inclusive_partial.t1 - partial_shorts.t1);
/*
			printf("Raking tid %d with exclusive_partial((%u,%u),(%u,%u))\n",
				threadIdx.x,
				exclusive_partial.t0 >> 16, exclusive_partial.t0 & 0x0000ffff,
				exclusive_partial.t1 >> 16, exclusive_partial.t1 & 0x0000ffff);
*/
			// Place short-packed partials into smem
			cta->smem_storage.short_prefixes_a[threadIdx.x] = exclusive_partial.t0;
			cta->smem_storage.short_prefixes_a[threadIdx.x + KernelPolicy::ByteGrid::RAKING_THREADS] = exclusive_partial.t1;

/*
			if ((threadIdx.x & (KernelPolicy::ByteGrid::RAKING_THREADS / 2) - 1) == 0) {
				int tid = threadIdx.x >> (KernelPolicy::ByteGrid::RAKING_THREADS - 1);
				cta->smem_storage.bin_inclusive[tid + 0] = inclusive_partial.t0 >> 16;
				cta->smem_storage.bin_inclusive[tid + 2] = inclusive_partial.t0 & 0x0000ffff;
				cta->smem_storage.bin_inclusive[tid + 4] = inclusive_partial.t1 >> 16;
				cta->smem_storage.bin_inclusive[tid + 6] = inclusive_partial.t1 & 0x0000ffff;
			}
*/
		}

		__syncthreads();

		// Extract the local ranks of each key
		IterateCycleElements<CYCLE, 0, 0>::ExtractRanks(cta, dispatch);

	}



	/**
	 * DecodeGlobalOffsets
	 */
	template <int ELEMENT, typename Cta>
	__device__ __forceinline__ void DecodeGlobalOffsets(Cta *cta)
	{
		Dispatch *dispatch = (Dispatch*) this;

		KeyType *linear_keys 	= (KeyType *) keys;
		SizeT *linear_offsets 	= (SizeT *) scatter_offsets;

		int bin = dispatch->DecodeBin(linear_keys[ELEMENT], cta);

		linear_offsets[ELEMENT] =
			cta->smem_storage.bin_carry[bin] +
			(KernelPolicy::THREADS * ELEMENT) + threadIdx.x;
/*
		printf("Tid %d scattering key[%d] (%d) with carry_bin %d to offset %d\n",
			threadIdx.x,
			ELEMENT,
			linear_keys[ELEMENT],
			cta->smem_storage.bin_carry[bin],
			linear_offsets[ELEMENT]);
*/
	}


	//---------------------------------------------------------------------
	// IterateCycles Structures
	//---------------------------------------------------------------------

	/**
	 * Iterate next cycle
	 */
	template <int CYCLE, int dummy = 0>
	struct IterateCycles
	{
		// ScanCycles
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void ScanCycles(Cta *cta, Tile *tile)
		{
			tile->ScanCycle<CYCLE>(cta);
			IterateCycles<CYCLE + 1>::ScanCycles(cta, tile);
		}
	};

	/**
	 * Terminate iteration
	 */
	template <int dummy>
	struct IterateCycles<CYCLES_PER_TILE, dummy>
	{
		// ScanCycles
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void ScanCycles(Cta *cta, Tile *tile) {}
	};


	//---------------------------------------------------------------------
	// IterateElements Structures
	//---------------------------------------------------------------------

	/**
	 * Iterate next tile element
	 */
	template <int ELEMENT, int dummy = 0>
	struct IterateElements
	{
		// DecodeGlobalOffsets
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void DecodeGlobalOffsets(Cta *cta, Tile *tile)
		{
			tile->DecodeGlobalOffsets<ELEMENT>(cta);
			IterateElements<ELEMENT + 1>::DecodeGlobalOffsets(cta, tile);
		}
	};


	/**
	 * Terminate iteration
	 */
	template <int dummy>
	struct IterateElements<TILE_ELEMENTS_PER_THREAD, dummy>
	{
		// DecodeGlobalOffsets
		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void DecodeGlobalOffsets(Cta *cta, Tile *tile) {}
	};



	//---------------------------------------------------------------------
	// Partition/scattering specializations
	//---------------------------------------------------------------------


	template <
		ScatterStrategy SCATTER_STRATEGY,
		int dummy = 0>
	struct PartitionTile;



	/**
	 * Specialized for two-phase scatter, keys-only
	 */
	template <
		ScatterStrategy SCATTER_STRATEGY,
		int dummy>
	struct PartitionTile
	{
		enum {
			MEM_BANKS 					= 1 << B40C_LOG_MEM_BANKS(__B40C_CUDA_ARCH__),
			DIGITS_PER_SCATTER_PASS 	= KernelPolicy::WARPS * (B40C_WARP_THREADS(__B40C_CUDA_ARCH__) / (MEM_BANKS)),
			SCATTER_PASSES 				= KernelPolicy::BINS / DIGITS_PER_SCATTER_PASS,
		};

		template <typename T>
		static __device__ __forceinline__ void Nop(T &t) {}


		template <typename Cta, typename Tile>
		static __device__ __forceinline__ void Invoke(
			SizeT cta_offset,
			const SizeT &guarded_elements,
			Cta *cta,
			Tile *tile)
		{
			// Load keys
			tile->LoadKeys(cta, cta_offset, guarded_elements);

			// Scan cycles
			IterateCycles<0>::ScanCycles(cta, tile);

			__syncthreads();

			// Scatter keys to smem by local rank
			util::io::ScatterTile<
				KernelPolicy::LOG_TILE_ELEMENTS_PER_THREAD,
				0,
				KernelPolicy::THREADS,
				util::io::st::NONE>::Scatter(
					cta->smem_storage.key_exchange,
					(KeyType (*)[1]) tile->keys,
					(int (*)[1]) tile->local_ranks);

			__syncthreads();

			// Gather keys linearly from smem (vec-1)
			util::io::LoadTile<
				KernelPolicy::LOG_TILE_ELEMENTS_PER_THREAD,
				0,
				KernelPolicy::THREADS,
				util::io::ld::NONE,
				false>::LoadValid(									// No need to check alignment
					(KeyType (*)[1]) tile->keys,
					cta->smem_storage.key_exchange,
					0);

			__syncthreads();

			// Compute global scatter offsets for gathered keys
			IterateElements<0>::DecodeGlobalOffsets(cta, tile);

			// Scatter keys to global bin partitions
			tile->ScatterKeys(cta, guarded_elements);
		}
	};





	//---------------------------------------------------------------------
	// Interface
	//---------------------------------------------------------------------

	/**
	 * Loads, decodes, and scatters a tile into global partitions
	 */
	template <typename Cta>
	__device__ __forceinline__ void Partition(
		SizeT cta_offset,
		const SizeT &guarded_elements,
		Cta *cta)
	{
		PartitionTile<KernelPolicy::SCATTER_STRATEGY>::Invoke(
			cta_offset,
			guarded_elements,
			cta,
			(Dispatch *) this);

	}

};


} // namespace downsweep
} // namespace partition
} // namespace b40c

