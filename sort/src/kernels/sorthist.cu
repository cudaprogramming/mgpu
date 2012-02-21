#pragma once

#include "common.cu"


////////////////////////////////////////////////////////////////////////////////
// StridedMultiScan
// Runs a scan over the per-block digit counts.

template<int NumThreads, int NumBits>
DEVICE2 uint StridedMultiScan(uint tid, uint x, volatile uint* shared,
	volatile uint* totals_shared) {

	const int NumDigits = 1<< NumBits;

	uint lane = (WARP_SIZE - 1) & tid;
	uint lane2 = (NumDigits - 1) & tid;
	uint warp = tid / WARP_SIZE;

	if(NumDigits < WARP_SIZE) {

		// Run an inclusive scan over repeated digits in the same warp.
		uint count = x;
		shared[tid] = x;

		#pragma unroll
		for(int i = 0; i < 5 - NumBits; ++i) {
			int offset = NumDigits<< i;
			if(lane >= offset) x += shared[tid - offset];
			shared[tid] = x;
		}
		uint laneExc = x - count;

		// Put the last digit in each warp (the warp total) into shared mem.
		__syncthreads();

		if((int)lane >= WARP_SIZE - NumDigits)
			shared[(WARP_SIZE + 1) * lane2 + warp] = x;
		__syncthreads();


		if(warp < NumDigits) {
			// Run NumDigits simultaneous parallel scans to sum up each digit.
			volatile uint* warpShared = shared + (WARP_SIZE + 1) * warp;

			x = warpShared[lane];
			uint count = x;

			#pragma unroll
			for(int i = 0; i < LOG_WARP_SIZE; ++i) {
				int offset = 1<< i;
				if(lane >= offset) x += warpShared[lane - offset];
				warpShared[lane] = x;
			}

			// Store the digit totals to shared mem.
			if(WARP_SIZE - 1 == lane)
				totals_shared[warp] = x;

			// Subtract count and put back in shared memory.
			warpShared[lane] = x - count;
		}
		__syncthreads();


		// Run the exclusive scan of digit totals.
		if(tid < NumDigits) {
			x = totals_shared[tid];
			uint count = x;

			#pragma unroll
			for(int i = 0; i < NumBits; ++i) {
				int offset = 1<< i;
				if(tid >= offset) x += totals_shared[tid - offset];
				if(i == NumBits - 1) x -= count;
				totals_shared[tid] = x;
			}
		}
		__syncthreads();

		// Add the three scanned values together for an exclusive offset for 
		// this lane.

		uint totalExc = totals_shared[lane2];
		uint warpExc = shared[lane2 * (WARP_SIZE + 1) + warp];
		return totalExc + warpExc + laneExc;
	} else {
		// There are 32, 64, or 128 digits. Run a simple sequential scan.
		shared[tid] = x;
		__syncthreads();

		// Runs a scan with 1, 2, or 4 warps. Probably slower than parallel scan
		// but much easier to follow.
		if(tid < NumDigits) {
			const int NumDuplicates = NumThreads / NumDigits;

			x = 0;
			#pragma unroll
			for(int i = 0; i < NumDuplicates; ++i) {
				uint y = shared[i * NumDigits + tid];
				shared[i * NumDigits + tid] = x;
				x += y;
			}

			// Store the totals at the end of shared.
			totals_shared[tid + tid / WARP_SIZE] = x;
		}
		__syncthreads();

		if(tid < WARP_SIZE) {
			if(5 == NumBits) {
				IntraWarpParallelScan<NumBits>(tid, totals_shared, false);
			} else if(6 == NumBits) {
				uint index = 2 * tid;
				index += index / WARP_SIZE;

				uint2 val;
				val.x = totals_shared[index];
				val.y = totals_shared[index + 1];

				val = IntraWarpScan64(tid, val, totals_shared, false, false, 0);

				totals_shared[index] = val.x;
				totals_shared[index + 1] = val.y;
			} else if(7 == NumBits) {
				uint index = 4 * tid;
				index += index / WARP_SIZE;

				uint4 val;
				val.x = totals_shared[index];
				val.y = totals_shared[index + 1];
				val.z = totals_shared[index + 2];
				val.w = totals_shared[index + 3];

				val = IntraWarpScan128(tid, val, totals_shared, false, false,
					0);

				totals_shared[index] = val.x;
				totals_shared[index + 1] = val.y;
				totals_shared[index + 2] = val.z;
				totals_shared[index + 3] = val.w;
			}
		}
		__syncthreads();

		uint exc = totals_shared[lane2 + lane2 / WARP_SIZE] + shared[tid];
		return exc;
	}
}


////////////////////////////////////////////////////////////////////////////////
// SortHist

template<int NumThreads, int NumBits>
DEVICE2 void SortHist(uint* blockTotals_global, uint numTasks, 
	uint* totalsScan_global) {
	
	const int NumDigits = 1<< NumBits;
	const int NumColumns = NumThreads / NumDigits;

	__shared__ uint counts_shared[2 * NumThreads];
	__shared__ uint totals_shared[NumThreads];
	
	uint tid = threadIdx.x;
	uint lane2 = (NumDigits - 1) & tid;

	// Figure out which interval of the block counts to assign to each column.
	uint col = tid / NumDigits;
	uint quot = numTasks / NumColumns;
	uint rem = (NumColumns - 1) & numTasks;

	int2 range = ComputeTaskRange(col, quot, rem, 1, numTasks);
	
	uint start = NumDigits * range.x + lane2;
	uint end = NumDigits * range.y;
	uint stride = NumDigits;

	////////////////////////////////////////////////////////////////////////////
	// Upsweep pass. Divide the blocks up over the warps. We want warp 0 to 
	// process the first section of digit counts, warp 1 process the second 
	// section, etc.
	uint laneCount = 0;
	for(int i = start; i < end; i += stride)
		laneCount += blockTotals_global[i];

	// Run a strided multiscan to situate each lane within the global scatter
	// order.
	uint laneExc = StridedMultiScan<NumThreads, NumBits>(tid, laneCount, 
		counts_shared, totals_shared);

	if(totalsScan_global && (tid < NumDigits))
		totalsScan_global[tid] = totals_shared[tid + tid / WARP_SIZE];

	// Iterate over the block totals once again, adding and inc'ing laneExc.
	for(int i = start; i < end; i += stride) {
		uint blockCount = blockTotals_global[i];
		blockTotals_global[i] = 4 * laneExc;
		laneExc += blockCount;
	}
}


#define GEN_SORTHIST_FUNC(Name, NumThreads, NumBits, BlocksPerSM)			\
																			\
extern "C" void __global__ Name(uint* blockTotals_global, uint numTasks,	\
	uint* totalsScan_global) {												\
	SortHist<NumThreads, NumBits>(blockTotals_global, numTasks,				\
		totalsScan_global);													\
}

GEN_SORTHIST_FUNC(SortHist_1, 1024, 1, 1)
GEN_SORTHIST_FUNC(SortHist_2, 1024, 2, 1)
GEN_SORTHIST_FUNC(SortHist_3, 1024, 3, 1)
GEN_SORTHIST_FUNC(SortHist_4, 1024, 4, 1)
GEN_SORTHIST_FUNC(SortHist_5, 1024, 5, 1)
GEN_SORTHIST_FUNC(SortHist_6, 1024, 6, 1)
GEN_SORTHIST_FUNC(SortHist_7, 1024, 7, 1)
