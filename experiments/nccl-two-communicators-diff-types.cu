#include <stdio.h>
#include "cuda_runtime.h"
#include "nccl.h"
#include "mpi.h"
#include <unistd.h>
#include <stdint.h>
#include <iostream>

#define MPI_CHECK(cmd) do {                      \
  int e = cmd;                                   \
  if (e != MPI_SUCCESS) {                        \
    printf("Failed: MPI error %s:%d '%d'\n",     \
     __FILE__,__LINE__, e);                      \
    exit(EXIT_FAILURE);                          \
  }                                              \
} while(0)

#define CUDA_CHECK(cmd) do {                     \
  cudaError_t e = cmd;                           \
  if (e != cudaSuccess) {                        \
    printf("Failed: CUDA error %s:%d '%s'\n",    \
     __FILE__,__LINE__,cudaGetErrorString(e));   \
    exit(EXIT_FAILURE);                          \
  }                                              \
} while(0)

#define NCCL_CHECK(cmd) do {                     \
  ncclResult_t r = cmd;                          \
  if (r != ncclSuccess) {                        \
    printf("Failed, NCCL error %s:%d '%s'\n",    \
     __FILE__,__LINE__,ncclGetErrorString(r));   \
    exit(EXIT_FAILURE);                          \
  }                                              \
} while(0)

static uint64_t getHostHash(const char *string) {
  // based on DJB2, result = result * 33 + char
  uint64_t result = 5381;
  for (int c = 0; string[c] != '\0'; c++) {
    result = ((result << 5) + result) + string[c];
  }
  return result;
}

static void getHostName(char *hostname, int maxlen) {
  gethostname(hostname, maxlen);
  for (int i = 0; i < maxlen; i++) {
    if (hostname[i] == '.') {
      hostname[i] = '\0';
      return;
    }
  }
}

int main(int argc, char *argv[]) {

  int size = 256 * 1024 * 1024; // 1GB data
  int myRank, nRanks, localRank = 0;

  // initializing MPI
  MPI_CHECK(MPI_Init(&argc, &argv));
  MPI_CHECK(MPI_Comm_rank(MPI_COMM_WORLD, &myRank));
  MPI_CHECK(MPI_Comm_size(MPI_COMM_WORLD, &nRanks));

  // calculating localRank based on hostname which is used in selecting a GPU
  uint64_t hostHashs[nRanks];
  char hostname[1024];
  getHostName(hostname, 1024);
  hostHashs[myRank] = getHostHash(hostname);
  MPI_CHECK(MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, hostHashs,
                          sizeof(uint64_t), MPI_BYTE, MPI_COMM_WORLD));
  for (int p = 0; p < nRanks; p++) {
    if (p == myRank) {
      break;
    }
    if (hostHashs[p] == hostHashs[myRank]) {
      localRank++;
    }
  }

  ncclUniqueId id[2];
  ncclComm_t comm[2];
  float *sendbuff32, *recvbuff32;
  half *sendbuff16, *recvbuff16;
  cudaStream_t stream[2];

  // get NCCL unique ID at rank 0 and broadcast it to all others
  if (myRank == 0) {
    ncclGetUniqueId(&id[0]);
    ncclGetUniqueId(&id[1]);
  }
  MPI_CHECK(MPI_Bcast((void *) &id[0], sizeof(id[0]), MPI_BYTE, 0, MPI_COMM_WORLD));
  MPI_CHECK(MPI_Bcast((void *) &id[1], sizeof(id[1]), MPI_BYTE, 0, MPI_COMM_WORLD));

  // picking a GPU based on localRank, allocate device buffers
  std::cout << "Picking Device: " << localRank << " for MPI Rank: " << myRank
            << "/" << nRanks << std::endl;
  CUDA_CHECK(cudaSetDevice(localRank));

  CUDA_CHECK(cudaMalloc(&sendbuff32, size * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&recvbuff32, size * sizeof(float)));

  CUDA_CHECK(cudaMalloc(&sendbuff16, 2 * size * sizeof(half)));
  CUDA_CHECK(cudaMalloc(&recvbuff16, 2 * size * sizeof(half)));

  CUDA_CHECK(cudaStreamCreate(&stream[0]));
  CUDA_CHECK(cudaStreamCreate(&stream[1]));

  // initializing NCCL
  std::cout << "Init NCCL for Rank: " << myRank << "/" << nRanks << std::endl;
  NCCL_CHECK(ncclCommInitRank(&comm[0], nRanks, id[0], myRank));
  NCCL_CHECK(ncclCommInitRank(&comm[1], nRanks, id[1], myRank));

  float *tmpCpu32 = (float *) malloc(10 * sizeof(float));
  half *tmpCpu16 = (half *) malloc(10 * sizeof(half));

  // communicating using NCCL
  for (int i = 0; i < 1; ++i) {
    CUDA_CHECK(cudaMemset(sendbuff32, 1.1111 * (i + 1), size * sizeof(float)));
    CUDA_CHECK(cudaMemset(sendbuff16, 0.2222 * (i + 1), 2 * size * sizeof(half)));

    // std::cout << std::endl << "Communication Test [" << i << "]" << std::endl;

    ///////////////////////////
    if (myRank == 0) {
      cudaMemcpy(tmpCpu32, sendbuff32, 10 * sizeof(float), cudaMemcpyDeviceToHost);
      for (int j = 1; j < 5; ++j) {
        std::cout << "==== 32 BEFORE ALLREDUCE MPI RANK " << myRank << ", INDEX " << j << ": "
                  << static_cast<float>(*(tmpCpu32 + j)) << std::endl;
      }
    }
    /*
      if (myRank == 1) {
      cudaMemcpy(tmpCpu16, sendbuff16, 10 * sizeof(half), cudaMemcpyDeviceToHost);
      for (int j = 1; j < 5; ++j) {
      std::cout << "---- 16 BEFORE ALLREDUCE MPI RANK " << myRank << ", INDEX " << j << ": " << static_cast<half>(*(tmpCpu16 + j)) << std::endl;
      }
      }
    */
    ///////////////////////////

    if (myRank == 0) {
      std::cout << "==== 32 Rank " << myRank << " before ncclAllReduce" << std::endl;
      NCCL_CHECK(ncclAllReduce((const void *) sendbuff32, (void *) recvbuff32, size,
                               ncclFloat, ncclSum, comm[1], stream[1]));
      std::cout << "==== 32 Rank " << myRank << " before stream sync" << std::endl;
      CUDA_CHECK(cudaStreamSynchronize(stream[1]));
      std::cout << "==== 32 Rank " << myRank << " finish stream sync" << std::endl;

      std::cout << "---- 16 Rank " << myRank << " before ncclAllReduce" << std::endl;
      NCCL_CHECK(ncclAllReduce((const void *) sendbuff16, (void *) recvbuff16, 2 * size,
                               ncclHalf, ncclSum, comm[0], stream[0]));
      std::cout << "---- 16 Rank " << myRank << " before stream sync" << std::endl;
      CUDA_CHECK(cudaStreamSynchronize(stream[0]));
      std::cout << "---- 16 Rank " << myRank << " finish stream sync" << std::endl;
    }

    if (myRank == 1) {
      std::cout << "---- 16 Rank " << myRank << " before ncclAllReduce" << std::endl;
      NCCL_CHECK(ncclAllReduce((const void *) sendbuff16, (void *) recvbuff16, 2 * size,
                               ncclHalf, ncclSum, comm[0], stream[0]));
      std::cout << "---- 16 Rank " << myRank << " before stream sync" << std::endl;
      CUDA_CHECK(cudaStreamSynchronize(stream[0]));
      std::cout << "---- 16 Rank " << myRank << " finish stream sync" << std::endl;

      std::cout << "==== 32 Rank " << myRank << " before ncclAllReduce" << std::endl;
      NCCL_CHECK(ncclAllReduce((const void *) sendbuff32, (void *) recvbuff32, size,
                               ncclFloat, ncclSum, comm[1], stream[1]));
      std::cout << "==== 32 Rank " << myRank << " before stream sync" << std::endl;
      CUDA_CHECK(cudaStreamSynchronize(stream[0]));
      std::cout << "==== 32 Rank " << myRank << " finish stream sync" << std::endl;
    }

    ///////////////////////////
    if (myRank == 0) {
      cudaMemcpy(tmpCpu32, recvbuff32, 10 * sizeof(float), cudaMemcpyDeviceToHost);
      for (int j = 1; j < 5; ++j) {
        std::cout << "==== 32 AFTER ALLREDUCE MPI RANK " << myRank << ", INDEX " << j << ": "
                  << static_cast<float>(*(tmpCpu32 + j)) << std::endl;
      }
    }
    /*
    if (myRank == 1) {
      cudaMemcpy(tmpCpu16, recvbuff16, 10 * sizeof(half), cudaMemcpyDeviceToHost);
      for (int j = 1; j < 5; ++j) {
	std::cout << "---- 16 AFTER ALLREDUCE MPI RANK " << myRank << ", INDEX " << j << ": " << static_cast<half>(*(tmpCpu16 + j)) << std::endl;
      }
    }
    */
    //////////////////////////
  }

  // free device buffers
  CUDA_CHECK(cudaFree(sendbuff32));
  CUDA_CHECK(cudaFree(recvbuff32));

  CUDA_CHECK(cudaFree(sendbuff16));
  CUDA_CHECK(cudaFree(recvbuff16));

  free(tmpCpu32);
  free(tmpCpu16);

  // finalizing NCCL
  ncclCommDestroy(comm[0]);
  ncclCommDestroy(comm[1]);

  // finalizing MPI
  MPI_CHECK(MPI_Finalize());

  std::cout << "[MPI Rank " << myRank << "] Success." << std::endl;
  return 0;
}
