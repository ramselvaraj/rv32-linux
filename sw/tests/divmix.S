# Regression: DIV/REM (signed) and DIVU/REMU (unsigned) interleaved. The divider once
# took signedness from the previous operation, which the stock tests never exposed.
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  li   s0, 0x80085fff
  li   s1, 64
  li   s2, -7
  li   s3, 2

  TEST_CASE(2,  a0, 0x0200217f, divu a0, s0, s1)
  TEST_CASE(3,  a0, 0xfffffffd, div  a0, s2, s3)      # -7 / 2 = -3
  TEST_CASE(4,  a0, 0x0200217f, divu a0, s0, s1)
  TEST_CASE(5,  a0, 0xffffffff, rem  a0, s2, s3)      # -7 % 2 = -1
  TEST_CASE(6,  a0, 0x0000003f, remu a0, s0, s1)
  TEST_CASE(7,  a0, 0x7ffffffc, divu a0, s2, s3)      # 0xfffffff9 / 2
  TEST_CASE(8,  a0, 0xfe002180, div  a0, s0, s1)      # 0x80085fff is negative as signed
  TEST_CASE(9,  a0, 0xffffffff, divu a0, s0, x0)      # divide by zero
  TEST_CASE(10, a0, 0x80085fff, remu a0, s0, x0)

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
