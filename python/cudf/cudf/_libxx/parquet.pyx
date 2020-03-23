# Copyright (c) 2019-2020, NVIDIA CORPORATION.

# cython: boundscheck = False

import cudf
import errno
import os
import pyarrow as pa
import json

from cython.operator import dereference
import numpy as np

from cudf.utils.dtypes import np_to_pa_dtype, is_categorical_dtype
from libc.stdlib cimport free
from libc.stdint cimport uint8_t
from libcpp.memory cimport unique_ptr, make_unique
from libcpp.string cimport string
from libcpp.map cimport map
from libcpp.vector cimport vector

from cudf._libxx.cpp.types cimport size_type
from cudf._libxx.table cimport Table
from cudf._libxx.cpp.table.table cimport table
from cudf._libxx.cpp.table.table_view cimport (
    table_view
)
from cudf._libxx.move cimport move
from cudf._libxx.cpp.io.functions cimport (
    write_parquet_args,
    write_parquet as parquet_writer,
    merge_rowgroup_metadata as parquet_merge_metadata,
    read_parquet_args,
    read_parquet as parquet_reader
)
from cudf._libxx.io.utils cimport (
    make_source_info
)

cimport cudf._libxx.cpp.types as cudf_types
cimport cudf._libxx.cpp.io.types as cudf_io_types

cdef class BufferArrayFromVector:
    cdef unsigned length
    cdef unique_ptr[vector[uint8_t]] in_vec

    # these two things declare part of the buffer interface
    cdef Py_ssize_t shape[2]
    cdef Py_ssize_t strides[2]

    cdef set_ptr(self, unique_ptr[vector[uint8_t]] in_vec):
        self.in_vec = move(in_vec)
        self.length = dereference(self.in_vec).size()

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        cdef Py_ssize_t itemsize = sizeof(uint8_t)

        self.shape[0] = 1 # ncolumns
        self.shape[1] = self.length # nrows

        self.strides[1] = 1 # 4 bytes per int
        self.strides[0] = 1 * self.length # only one row but if there were more, this is the separation

        buffer.buf = <uint8_t *>&(dereference(self.in_vec)[0])

        buffer.format = NULL # byte
        buffer.internal = NULL                  
        buffer.itemsize = itemsize
        buffer.len = self.length * itemsize   # product(shape) * itemsize
        buffer.ndim = 2
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = self.shape
        buffer.strides = self.strides
        buffer.suboffsets = NULL          

    def __releasebuffer__(self, Py_buffer *buffer):
        pass

cpdef generate_pandas_metadata(Table table, index):
    col_names = []
    types = []
    index_levels = []
    index_descriptors = []

    # Columns
    for name, col in table._data.items():
        col_names.append(name)
        if is_categorical_dtype(col):
            raise ValueError(
                "'category' column dtypes are currently not "
                + "supported by the gpu accelerated parquet writer"
            )
        else:
            types.append(np_to_pa_dtype(col.dtype))

    # Indexes
    if index is not False:
        for name in table._index.names:
            if name is not None:
                if isinstance(table._index, cudf.core.multiindex.MultiIndex):
                    idx = table.index.get_level_values(name)
                else:
                    idx = table.index

                if isinstance(idx, cudf.core.index.RangeIndex):
                    descr = {
                        "kind": "range",
                        "name": table.index.name,
                        "start": table.index._start,
                        "stop": table.index._stop,
                        "step": 1,
                    }
                else:
                    descr = name
                    col_names.append(name)
                    if is_categorical_dtype(idx):
                        raise ValueError(
                            "'category' column dtypes are currently not "
                            + "supported by the gpu accelerated parquet writer"
                        )
                    else:
                        types.append(np_to_pa_dtype(idx.dtype))
                    index_levels.append(idx)
                index_descriptors.append(descr)
            else:
                col_names.append(name)

    metadata = pa.pandas_compat.construct_metadata(
        table,
        col_names,
        index_levels,
        index_descriptors,
        index,
        types,
    )

    md = metadata[b'pandas']
    json_str = md.decode("utf-8")
    return json_str

cpdef read_parquet(filepath_or_buffer, columns=None, row_group=None,
                   row_group_count=None, skip_rows=None, num_rows=None,
                   strings_to_categorical=False, use_pandas_metadata=True):
    """
    Cython function to call into libcudf API, see `read_parquet`.

    See Also
    --------
    cudf.io.parquet.read_parquet
    cudf.io.parquet.to_parquet
    """

    cdef cudf_io_types.source_info source = make_source_info(
        filepath_or_buffer)

    # Setup parquet reader arguments
    cdef read_parquet_args args = read_parquet_args(source)

    if columns is not None:
        args.columns.reserve(len(columns))
        for col in columns or []:
            args.columns.push_back(str(col).encode())
    args.strings_to_categorical = strings_to_categorical
    args.use_pandas_metadata = use_pandas_metadata

    args.skip_rows = skip_rows if skip_rows is not None else 0
    args.num_rows = num_rows if num_rows is not None else -1
    args.row_group = row_group if row_group is not None else -1
    args.row_group_count = row_group_count \
        if row_group_count is not None else -1
    args.timestamp_type = cudf_types.data_type(cudf_types.type_id.EMPTY)

    # Read Parquet
    cdef cudf_io_types.table_with_metadata c_out_table

    with nogil:
        c_out_table = move(parquet_reader(args))

    column_names = [x.decode() for x in c_out_table.metadata.column_names]

    # Access the Parquet user_data json to find the index
    index_col = ''
    cdef map[string, string] user_data = c_out_table.metadata.user_data
    json_str = user_data[b'pandas'].decode('utf-8')
    if json_str != "":
        meta = json.loads(json_str)
        if 'index_columns' in meta and len(meta['index_columns']) > 0:
            index_col = meta['index_columns'][0]

    df = cudf.DataFrame._from_table(
        Table.from_unique_ptr(move(c_out_table.tbl),
                              column_names=column_names)
    )

    # Set the index column
    if index_col is not '' and isinstance(index_col, str):
        if index_col in column_names:
            df = df.set_index(index_col)
            new_index_name = pa.pandas_compat._backwards_compatible_index_name(
                df.index.name, df.index.name
            )
            df.index.name = new_index_name
        else:
            if use_pandas_metadata:
                df.index.name = index_col

    return df

cpdef write_parquet(
        Table table,
        path,
        index=None,
        compression=None,
        statistics="ROWGROUP",
        metadata_file_path=None):
    """
    Cython function to call into libcudf API, see `write_parquet`.

    See Also
    --------
    cudf.io.parquet.write_parquet
    """

    # Create the write options
    cdef string filepath = <string>str(path).encode()
    cdef cudf_io_types.sink_info sink = cudf_io_types.sink_info(filepath)
    cdef unique_ptr[cudf_io_types.table_metadata] tbl_meta = \
        make_unique[cudf_io_types.table_metadata]()

    cdef vector[string] column_names
    cdef map[string, string] user_data
    cdef table_view tv = table.data_view()

    if index is not False:
        tv = table.view()
        if isinstance(table._index, cudf.core.multiindex.MultiIndex):
            for idx_name in table._index.names:
                column_names.push_back(str.encode(idx_name))
        else:
            if table._index.name is not None:
                column_names.push_back(str.encode(table._index.name))
            else:
                # No named index exists so just write out columns
                tv = table.data_view()

    for col_name in table._column_names:
        column_names.push_back(str.encode(col_name))

    pandas_metadata = generate_pandas_metadata(table, index)
    user_data[str.encode("pandas")] = str.encode(pandas_metadata)

    # Set the table_metadata
    tbl_meta.get().column_names = column_names
    tbl_meta.get().user_data = user_data

    cdef cudf_io_types.compression_type comp_type
    if compression is None:
        comp_type = cudf_io_types.compression_type.NONE
    elif compression == "snappy":
        comp_type = cudf_io_types.compression_type.SNAPPY
    else:
        raise ValueError("Unsupported `compression` type")

    cdef cudf_io_types.statistics_freq stat_freq
    statistics = statistics.upper()
    if statistics == "NONE":
        stat_freq = cudf_io_types.statistics_freq.STATISTICS_NONE
    elif statistics == "ROWGROUP":
        stat_freq = cudf_io_types.statistics_freq.STATISTICS_ROWGROUP
    elif statistics == "PAGE":
        stat_freq = cudf_io_types.statistics_freq.STATISTICS_PAGE
    else:
        raise ValueError("Unsupported `statistics_freq` type")

    cdef write_parquet_args args
    cdef unique_ptr[vector[uint8_t]] out_metadata_c

    # Perform write
    with nogil:
        args = write_parquet_args(sink,
                                  tv,
                                  tbl_meta.get(),
                                  comp_type,
                                  stat_freq)

    if metadata_file_path is not None:
        args.metadata_out_file_path = str.encode(metadata_file_path)
        args.return_filemetadata = True

    with nogil:
        out_metadata_c = move(parquet_writer(args))

    if metadata_file_path is not None:
        out_metadata_py = BufferArrayFromVector()
        out_metadata_py.set_ptr(move(out_metadata_c))
        return np.asarray(out_metadata_py)
    else:
        return None

cpdef merge_filemetadata(filemetadata_list):
    """
    Cython function to call into libcudf API, see `merge_rowgroup_metadata`.

    See Also
    --------
    cudf.io.parquet.merge_rowgroup_metadata
    """
    cdef vector[unique_ptr[vector[uint8_t]]] list_c
    cdef vector[uint8_t] blob_c
    cdef unique_ptr[vector[uint8_t]] output_c
    cdef bytes output_py

    for blob_py in filemetadata_list:
        blob_c = blob_py
        list_c.push_back(make_unique[vector[uint8_t]](blob_c))

    with nogil:
        output_c = move(parquet_merge_metadata(list_c))

    out_metadata_py = BufferArrayFromVector()
    out_metadata_py.set_ptr(move(output_c))
    return np.asarray(out_metadata_py)