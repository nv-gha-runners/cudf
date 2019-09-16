/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION.
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
 */

#pragma once

#include "cudf.h"

#include <cstddef>

/**---------------------------------------------------------------------------*
 * @file types.hpp
 * @brief Type declarations for libcudf.
 *
 *---------------------------------------------------------------------------**/

/**---------------------------------------------------------------------------*
 * @brief Forward declaration of cudaStream_t
 *---------------------------------------------------------------------------**/
using cudaStream_t = struct CUstream_st*;

namespace bit_mask {
using bit_mask_t = uint32_t;
}

// Forward declarations
namespace rmm {
class device_buffer;
namespace mr {
class device_memory_resource;
device_memory_resource* get_default_resource();
}  // namespace mr

}  // namespace rmm

namespace cudf {

// Forward declaration
struct table;
class column;
class column_view;
class mutable_column_view;

namespace exp {
class table;
}
class table_view;
class mutable_table_view;

using size_type = int32_t;
using bitmask_type = uint32_t;

enum type_id {
  EMPTY = 0,  ///< Always null with no underlying data
  INT8,       ///< 1 byte signed integer
  INT16,      ///< 2 byte signed integer
  INT32,      ///< 4 byte signed integer
  INT64,      ///< 8 byte signed integer
  FLOAT32,    ///< 4 byte floating point
  FLOAT64,    ///< 8 byte floating point
  BOOL8,      ///< Boolean using one byte per value, 0 == false, else true
  DATE32,     ///< days since Unix Epoch in int32
  TIMESTAMP,  ///< duration of specified resolution since Unix Epoch in int64
  CATEGORY,   ///< Categorial/Dictionary type
  STRING,     ///< String elements
  // `NUM_TYPE_IDS` must be last!
  NUM_TYPE_IDS  ///< Total number of type ids
};

/**---------------------------------------------------------------------------*
 * @brief Indicator for the logical data type of an element in a column.
 *
 * Simple types can be be entirely described by their `id()`, but some types
 * require additional metadata to fully describe elements of that type.
 *---------------------------------------------------------------------------**/
class data_type {
 public:
  data_type() = default;
  ~data_type() = default;
  data_type(data_type const&) = default;
  data_type(data_type&&) = default;
  data_type& operator=(data_type const&) = default;
  data_type& operator=(data_type&&) = default;

  explicit constexpr data_type(type_id id) : _id{id} {}

  type_id id() const noexcept { return _id; }

 private:
  type_id _id{EMPTY};
  // Store additional type specific metadata, timezone, decimal precision and
  // scale, etc.
};

/**---------------------------------------------------------------------------*
 * @brief Indicates an unknown null count.
 *
 * Use this value when constructing any column-like object to indicate that
 * the null count should be computed on the first invocation of `null_count()`.
 *---------------------------------------------------------------------------**/
static constexpr size_type UNKNOWN_NULL_COUNT{-1};

}  // namespace cudf
