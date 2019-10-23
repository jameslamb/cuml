#
# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cuml.neighbors import NearestNeighbors

import numpy as np
import pandas as pd
import cudf
import ctypes
import cuml
import warnings

from cuml.common.base import Base
from cuml.utils import get_cudf_column_ptr, get_dev_array_ptr, \
    input_to_dev_array, zeros, row_matrix

from cython.operator cimport dereference as deref

from cuml.common.handle cimport cumlHandle

import scipy.stats as stats


from libcpp cimport bool
from libcpp.memory cimport shared_ptr

import rmm
from libc.stdlib cimport malloc, free

from libc.stdint cimport uintptr_t, int64_t
from libc.stdlib cimport calloc, malloc, free

from numba import cuda
import rmm


cimport cuml.common.handle
cimport cuml.common.cuda

cdef extern from "<vector>" namespace "std":
    cdef cppclass vector[T]:
        cppclass iterator:
            T operator*()
            iterator operator++()
            bint operator==(iterator)
            bint operator!=(iterator)
        vector()
        void push_back(T&)
        T& operator[](int)
        T& at(int)
        iterator begin()
        iterator end()
        void resize(size_t n)
        int size()

cdef extern from "cumlprims/opg/matrix/data.hpp" namespace \
        "MLCommon::Matrix":

    cdef cppclass Data[T]:
        Data(T *ptr, size_t totalSize)

    cdef cppclass floatData_t:
        floatData_t(float *ptr, size_t totalSize)
        float *ptr
        size_t totalSize

ctypedef Data[int64_t] int64Data_t


cdef extern from "cumlprims/opg/matrix/part_descriptor.hpp" namespace \
        "MLCommon::Matrix":

    cdef cppclass RankSizePair:
        int rank
        size_t size

    cdef cppclass PartDescriptor:
        PartDescriptor(size_t M,
                       size_t N,
                       vector[RankSizePair*] &partsToRanks,
                       int myrank)

cdef extern from "cumlprims/opg/selection/knn.hpp" namespace \
        "MLCommon::Selection::opg":

    cdef void brute_force_knn(
        cumlHandle &handle,
        vector[int64Data_t*] &out_I,
        vector[floatData_t*] &out_D,
        vector[floatData_t*] &idx_data,
        PartDescriptor &idx_desc,
        vector[floatData_t*] &query_data,
        PartDescriptor &query_desc,
        bool rowMajorIndex,
        bool rowMajorQuery,
        int k,
        size_t batch_size,
        bool verbose
    ) except +


class NearestNeighborsMG(NearestNeighbors):
    """
    Multi-node multi-GPU Nearest Neighbors kneighbors query.

    NOTE: This implementation of NearestNeighbors is meant to be
    used with an initialized cumlCommunicator instance inside an
    existing distributed system. Refer to the Dask NearestNeighbors
     implementation in `cuml.dask.neighbors.nearest_neighbors`.
    """
    def __init__(self, batch_size=1<<21, **kwargs):
        super(NearestNeighborsMG, self).__init__(**kwargs)
        self.batch_size = batch_size

    def _build_dataFloat(self, arr_interfaces):
        """
        Instantiate a container object for a float data pointer
        and size.
        :param arr_interfaces:
        :return:
        """
        cdef vector[floatData_t*] *dataF = new vector[floatData_t*]()

        cdef uintptr_t input_ptr
        for x_i in range(len(arr_interfaces)):
            x = arr_interfaces[x_i]
            input_ptr = x["data"]
            data = <floatData_t*> malloc(sizeof(floatData_t))
            data.ptr = <float *> input_ptr
            data.totalSize = < size_t > (x["shape"][0] *
                                         x["shape"][1] *
                                         sizeof(float))

            dataF.push_back(data)

        return <size_t>dataF

    def _free_mem(self, index_vec, index_desc,
                 query_vec, query_desc,
                 out_i_vec, out_d_vec,
                 local_index_parts,
                 local_query_parts):

        cdef vector[floatData_t *] *index_vec_c \
            = <vector[floatData_t *]*><size_t>index_vec
        cdef PartDescriptor *index_desc_c \
            = <PartDescriptor*><size_t>index_desc
        for elm in range(index_vec_c.size()):
            free(index_vec_c.at(elm))
        free(index_vec_c)
        free(index_desc_c)

        cdef vector[floatData_t *] *query_vec_c \
            = <vector[floatData_t *]*><size_t>query_vec
        cdef PartDescriptor *query_desc_c \
            = <PartDescriptor*><size_t>query_desc
        for elm in range(query_vec_c.size()):
            free(query_vec_c.at(elm))
        free(query_vec_c)
        free(query_desc_c)

        cdef vector[int64Data_t *] *out_i_vec_c \
            = <vector[int64Data_t *]*><size_t>out_i_vec
        cdef int64Data_t *del_idx_ptr
        for elm in range(out_i_vec_c.size()):
            del_idx_ptr = out_i_vec_c.at(elm)
            del del_idx_ptr
        free(out_i_vec_c)

        cdef vector[floatData_t *] *out_d_vec_c \
            = <vector[floatData_t *]*><size_t>out_d_vec
        cdef floatData_t *del_ptr
        for elm in range(out_d_vec_c.size()):
            del_ptr = out_d_vec_c.at(elm)
            del del_ptr
        free(out_d_vec_c)

        cdef vector[RankSizePair *] *local_index_parts_c \
            = <vector[RankSizePair *]*><size_t>local_index_parts
        for elm in range(local_index_parts_c.size()):
            free(local_index_parts_c.at(elm))
        free(local_index_parts_c)

        cdef vector[RankSizePair *] *local_query_parts_c \
            = <vector[RankSizePair *]*><size_t>local_query_parts
        for elm in range(local_query_parts_c.size()):
            free(local_query_parts_c.at(elm))
        free(local_query_parts_c)


    def _freeFloatD(self, data):
        cdef uintptr_t data_ptr = data
        cdef vector[floatData_t*] *d = <vector[floatData_t*]*>data_ptr
        for x_i in range(d.size()):
            free(d.at(x_i))
        free(d)

    def kneighbors(self, indices, index_m, n, index_partsToRanks,
                   queries, query_m, query_partsToRanks,
                   rank, n_neighbors=None, convert_dtype=True):
        """
        Query the kneighbors of an index
        :param indices: [__cuda_array_interface__] of local index partitions
        :param index_m: number of total index rows
        :param n: number of columns
        :param index_partsToRanks: mappings of index partitions to ranks
        :param queries: [__cuda_array_interface__] of local query partitions
        :param query_m: number of total query rows
        :param query_partsToRanks: mappings of query partitions to ranks
        :param rank: int rank of current worker
        :param k: int number of nearest neighbors to query
        :return:
        """

        n_neighbors = self.n_neighbors if n_neighbors is None else n_neighbors

        self.n_dims = n

        cdef cumlHandle* handle_ = <cumlHandle*><size_t>self.handle.getHandle()

        cdef vector[RankSizePair*] *index_vec = new vector[RankSizePair*]()
        cdef vector[RankSizePair*] *query_vec = new vector[RankSizePair*]()

        query_ints = []
        index_ints = []
        for arr in queries:
            X_m, input_ptr, n_rows, n_cols, dtype = \
                input_to_dev_array(arr, order="F",
                                   convert_to_dtype=(np.float32
                                                     if convert_dtype
                                                     else None),
                                   check_dtype=[np.float32])
            query_ints.append({"obj": X_m,
                               "data": input_ptr,
                               "shape": (n_rows, n_cols)})

        for arr in indices:
            X_m, input_ptr, n_rows, n_cols, dtype = \
                input_to_dev_array(arr, order="F",
                                   convert_to_dtype=(np.float32
                                                     if convert_dtype
                                                     else None),
                                   check_dtype=[np.float32])
            index_ints.append({"obj": X_m,
                               "data": input_ptr,
                               "shape": (n_rows, n_cols)})

        for rankSize in index_partsToRanks:
            rank, size = rankSize
            index = <RankSizePair*> malloc(sizeof(RankSizePair))
            index.rank = <int>rank
            index.size = <size_t>size

            index_vec.push_back(index)

        for rankSize in query_partsToRanks:
            rank, size = rankSize
            query = < RankSizePair*> malloc(sizeof(RankSizePair))
            query.rank = < int > rank
            query.size = < size_t > size

            query_vec.push_back(query)

        cdef vector[floatData_t*] *local_index_parts \
            = <vector[floatData_t*]*><size_t>self._build_dataFloat(index_ints)

        cdef vector[floatData_t*] *local_query_parts \
            = <vector[floatData_t*]*><size_t>self._build_dataFloat(query_ints)

        cdef PartDescriptor *index_descriptor \
            = new PartDescriptor(<size_t>index_m,
                                 <size_t>n,
                                 <vector[RankSizePair*]>deref(index_vec),
                                 <int>rank)

        cdef PartDescriptor *query_descriptor \
            = new PartDescriptor(<size_t>query_m,
                                 <size_t>n,
                                 <vector[RankSizePair*]>deref(index_vec),
                                 <int>rank)

        cdef vector[int64Data_t*] *out_i_vec \
            = new vector[int64Data_t*]()
        cdef vector[floatData_t*] *out_d_vec \
            = new vector[floatData_t*]()

        output_i_arrs = []
        output_d_arrs = []

        cdef uintptr_t i_ptr
        cdef uintptr_t d_ptr

        for query_part in query_ints:

            n_rows = query_part["shape"][0]
            i_ary = rmm.to_device(zeros((n_rows, n_neighbors),
                                        order="C",
                                        dtype=np.int64))
            d_ary = rmm.to_device(zeros((n_rows, n_neighbors),
                                        order="C",
                                        dtype=np.float32))

            output_i_arrs.append(i_ary)
            output_d_arrs.append(d_ary)

            i_ptr = get_dev_array_ptr(i_ary)
            d_ptr = get_dev_array_ptr(d_ary)

            out_i_vec.push_back(new int64Data_t(
                <int64_t*>i_ptr, n_rows * n_neighbors))

            out_d_vec.push_back(new floatData_t(
                <float*>d_ptr, n_rows * n_neighbors))

        brute_force_knn(
            handle_[0],
            deref(out_i_vec),
            deref(out_d_vec),
            deref(local_index_parts),
            deref(index_descriptor),
            deref(local_query_parts),
            deref(query_descriptor),
            False,
            False,
            n_neighbors,
            <size_t>self.batch_size,
            <bool>self.verbose
        )

        self.handle.sync()

        output_i = list(map(lambda x: cudf.DataFrame.from_gpu_matrix(x),
                            output_i_arrs))
        output_d = list(map(lambda x: cudf.DataFrame.from_gpu_matrix(x),
                            output_d_arrs))

        self._free_mem(<size_t>index_vec,
                       <size_t>index_descriptor,
                       <size_t>query_vec,
                       <size_t>query_descriptor,
                       <size_t>out_i_vec,
                       <size_t>out_d_vec,
                       <size_t>local_index_parts,
                       <size_t>local_query_parts)

        return output_i, output_d
