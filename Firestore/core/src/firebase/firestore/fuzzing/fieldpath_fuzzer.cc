/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstddef>
#include <cstdint>

#include "Firestore/core/src/firebase/firestore/model/field_path.h"

namespace firebase {
namespace firestore {
namespace fuzzing {
namespace fieldpath {

using firebase::firestore::model::FieldPath;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const char* str_ptr = reinterpret_cast<const char*>(data);
  absl::string_view str_view{str_ptr, size};

  try {
    FieldPath fp = FieldPath::FromServerFormat(str_view);
  } catch (...) {
    // Ignore caught exceptions.
  }
  return 0;
}

}  // namespace fieldpath
}  // namespace fuzzing
}  // namespace firestore
}  // namespace firebase
