/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

// This is the optimization pattern definition file for TensorFlow Lite.

include "mlir/IR/OpBase.td"
include "mlir/Dialect/StandardOps/IR/Ops.td"
include "tensorflow/compiler/mlir/lite/ir/tfl_ops.td"
include "tensorflow/compiler/mlir/lite/utils/utils.td"
include "tensorflow/compiler/mlir/tensorflow/ir/tf_ops.td"

// Checks if the param passed is a F32 ElementsAttr.
def F32ElementsAttr : ElementsAttrBase<
  CPred<"$_self.isa<ElementsAttr>() && $_self.cast<ElementsAttr>().getType().getElementType().isF32()">,
        "float constant tensor">;

// Checks if the param passed is of NoneType.
def IsNoneType : Constraint<CPred<"$0.getType().isa<NoneType>()">>;

def ExtractSingleElementAsFloat : NativeCodeCall<
    "ExtractSingleElementAsFloat($_self.cast<ElementsAttr>())">;

// Checks if the value has rank at most 'n'.
class HasRankAtMost<int n> : Constraint<
    CPred<"$0.getType().cast<ShapedType>().getRank() <= " # n>>;

//===----------------------------------------------------------------------===//
// Ternary ops patterns.
//===----------------------------------------------------------------------===//
// Multi-pattern consisting of matching stand-alone convolution op followed by
// activation op.
multiclass FuseActFnIntoConvOpPat<dag ActFnOp, dag ActFnAttr> {
  def FuseActivationFuncWithConv#ActFnOp#ActFnAttr : Pat<
    (ActFnOp (TFL_Conv2DOp:$conv_out $input, $filter, $bias, $h_factor,
                 $w_factor, TFL_AF_None, $padding, $stride_h, $stride_w)),
    (TFL_Conv2DOp $input, $filter, $bias, $h_factor, $w_factor, ActFnAttr,
        $padding, $stride_h, $stride_w),
    [(HasOneUse $conv_out)]>;
  def FuseActivationFuncWithDepthwiseConv#ActFnOp#ActFnAttr : Pat<
    (ActFnOp (TFL_DepthwiseConv2DOp:$conv_out $input, $filter, $bias, $h_factor,
                $w_factor, TFL_AF_None, $padding, $stride_h, $stride_w,
                $multiplier)),
    (TFL_DepthwiseConv2DOp $input, $filter, $bias, $h_factor, $w_factor,
        ActFnAttr, $padding, $stride_h, $stride_w, $multiplier),
    [(HasOneUse $conv_out)]>;
}

multiclass FuseActFnIntoPoolOpPat<dag ActFnOp, dag ActFnAttr> {
  def FuseActivationFuncWithAvgPool#ActFnOp#ActFnAttr : Pat<
    (ActFnOp (TFL_AveragePool2DOp:$pool_out $input, $filter_height,
                  $filter_width, $padding, $stride_h, $stride_w, TFL_AF_None)),
    (TFL_AveragePool2DOp $input, $filter_height, $filter_width, $padding,
        $stride_h, $stride_w, ActFnAttr),
    [(HasOneUse $pool_out)]>;
  def FuseActivationFuncWithMaxPool#ActFnOp#ActFnAttr : Pat<
    (ActFnOp (TFL_MaxPool2DOp:$pool_out $input, $padding, $stride_w, $stride_h,
                  $filter_width, $filter_height, TFL_AF_None)),
    (TFL_MaxPool2DOp $input, $padding, $stride_w, $stride_h,
        $filter_width, $filter_height, ActFnAttr),
    [(HasOneUse $pool_out)]>;
}

// TODO(hinsu): Also fuse ops corresponding to SIGN_BIT fused
// activation functions.
// Currently we're not fusing tanh, sigmoid, hard_swish and other activations
// those cannot be simply translated into clamping.
foreach actFnPair = [[TFL_ReluOp, TFL_AF_Relu],
                     [TFL_Relu6Op, TFL_AF_Relu6],
                     [TFL_Relu1Op, TFL_AF_Relu1]] in {
  defm : FuseActFnIntoConvOpPat<actFnPair[0], actFnPair[1]>;
  defm : FuseActFnIntoPoolOpPat<actFnPair[0], actFnPair[1]>;
}

class CanFuseConvOrDepthwiseConv<string is_depthwise> : Constraint<
  CPred<"TFL::CanFuseConvOrDepthwiseConv($0, $1, " # is_depthwise # ")">>;

// If we see a binary op (add, sub) op adding a constant value to a convolution
// op with constant bias, we can fuse the binary op into the convolution op by
// constant folding the bias and the binary op's constant operand. The following
// pattern restricts to float constant values for now.
multiclass FuseBinaryOpToPrecedingAffine<dag binaryOp> {
  def FuseBinaryOpWithConv#binaryOp : Pat<
    (binaryOp (TFL_Conv2DOp:$output $input, $filter,
                (ConstantOp F32ElementsAttr:$bias), $h_factor, $w_factor,
                TFL_AF_None, $padding, $stride_h, $stride_w),
              (ConstantOp F32ElementsAttr:$value), $act_fn),
    (TFL_Conv2DOp $input, $filter,
      (binaryOp (ConstantOp $bias),
         (ConstantOp $value), TFL_AF_None),
      $h_factor, $w_factor, $act_fn, $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $filter, $value),
     (HasOneUse $output)]>;
  def FuseBinaryOpWithDepthwiseConv#binaryOp : Pat<
    (binaryOp (TFL_DepthwiseConv2DOp:$output $input, $filter,
                (ConstantOp F32ElementsAttr:$bias),
                $h_factor, $w_factor, TFL_AF_None, $padding, $stride_h,
                $stride_w, $multiplier),
              (ConstantOp F32ElementsAttr:$value), $act_fn),
    (TFL_DepthwiseConv2DOp $input, $filter,
      (binaryOp (ConstantOp $bias), (ConstantOp $value), TFL_AF_None),
      $h_factor, $w_factor, $act_fn, $padding, $stride_h, $stride_w,
      $multiplier),
    [(CanFuseConvOrDepthwiseConv<"true"> $filter, $value),
     (HasOneUse $output)]>;
   def FuseBinaryOpWithTransposeConv#binaryOp : Pat<
    (binaryOp (TFL_TransposeConvOp:$output $output_shape, $weights, $inputs,
                (ConstantOp F32ElementsAttr:$bias), $padding,
                $stride_h, $stride_w),
              (ConstantOp F32ElementsAttr:$value), TFL_AF_None),
    (TFL_TransposeConvOp $output_shape, $weights, $inputs,
      (binaryOp (ConstantOp $bias),
         (ConstantOp $value), TFL_AF_None),
      $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $weights, $value),
     (HasOneUse $output)]>;
  // Fuse for TransposeConv with no bias
  def FuseBinaryOpWithTransposeConvNoneBias#binaryOp : Pat<
    (binaryOp (TFL_TransposeConvOp:$output $output_shape, $weights, $inputs,
                (ConstantOp $bias), $padding,
                $stride_h, $stride_w),
              (ConstantOp F32ElementsAttr:$value), TFL_AF_None),
    (TFL_TransposeConvOp $output_shape, $weights, $inputs,
      (ConstantOp $value),
      $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $weights, $value),
     (IsNoneType $bias),
     (HasOneUse $output)]>;
}
foreach binaryOp = [TFL_AddOp, TFL_SubOp] in
  defm : FuseBinaryOpToPrecedingAffine<binaryOp>;

def ExpandTo4DForConv: NativeCodeCall<"ExpandTo4DForConv($0)">;

def ExpandTo4DForDepthwiseConv: NativeCodeCall<
  "ExpandTo4DForDepthwiseConv($0)">;

// If we see a (div or Mul) op (dividing/multiplying) a constant value
// to a convolution op with constant filter and bias, we can fuse the div/mul
// into the convolution op by constant folding
// the filter/bias and the div/mul op's constant operand.
// The following pattern restricts to float constant values for now.

multiclass FuseMulOrDivWithConv2dOrDepthwiseConv2d<dag BinaryOp> {
  def FuseMulOrDivWithDepthwiseConv#BinaryOp : Pat<
    (BinaryOp (TFL_DepthwiseConv2DOp:$output $input,
                (ConstantOp F32ElementsAttr:$filter),
                (ConstantOp F32ElementsAttr:$bias),
                $h_factor, $w_factor, TFL_AF_None, $padding, $stride_h,
                $stride_w, $multiplier),
              (ConstantOp F32ElementsAttr:$value), $act_fn),
    (TFL_DepthwiseConv2DOp $input,
      (BinaryOp
        (ConstantOp $filter),
        (ConstantOp (ExpandTo4DForDepthwiseConv $value)),
        TFL_AF_None),
      (BinaryOp
        (ConstantOp $bias),
        (ConstantOp $value),
        TFL_AF_None),
      $h_factor, $w_factor, $act_fn, $padding, $stride_h,
      $stride_w, $multiplier),
    [(CanFuseConvOrDepthwiseConv<"true"> $filter, $value),
     (HasOneUse $output)]>;
  def FuseMulOrDivWithConv#BinaryOp : Pat<
    (BinaryOp (TFL_Conv2DOp:$conv_output $input,
                (ConstantOp F32ElementsAttr:$filter),
                (ConstantOp F32ElementsAttr:$bias),
                $h_factor, $w_factor, TFL_AF_None,
                $padding, $stride_h, $stride_w),
              (ConstantOp F32ElementsAttr:$value), $act_fn),
    (TFL_Conv2DOp $input,
      (BinaryOp (ConstantOp $filter),
        (ConstantOp (ExpandTo4DForConv $value)),
        TFL_AF_None),
      (BinaryOp (ConstantOp $bias),
        (ConstantOp $value),
        TFL_AF_None),
      $h_factor, $w_factor, $act_fn, $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $filter, $value),
     (HasOneUse $conv_output)]>;
  def FuseMulOrDivWithTransposeConv#BinaryOp : Pat<
    (BinaryOp (TFL_TransposeConvOp:$output $output_shape,
                (ConstantOp F32ElementsAttr:$weights), $input,
                (ConstantOp F32ElementsAttr:$bias),
                $padding, $stride_h, $stride_w),
              (ConstantOp $value), TFL_AF_None),
    (TFL_TransposeConvOp $output_shape,
      (BinaryOp (ConstantOp $weights),
        (ConstantOp (ExpandTo4DForConv $value)),
        TFL_AF_None),
      $input,
      (BinaryOp (ConstantOp $bias),
        (ConstantOp $value),
        TFL_AF_None),
      $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $weights, $value),
     (HasOneUse $output)]>;
  def FuseMulOrDivWithTransposeConvWithNoneBias#BinaryOp : Pat<
    (BinaryOp (TFL_TransposeConvOp:$output $output_shape,
                (ConstantOp F32ElementsAttr:$weights), $input,
                (ConstantOp $bias),
                $padding, $stride_h, $stride_w),
              (ConstantOp $value), TFL_AF_None),
    (TFL_TransposeConvOp $output_shape,
      (BinaryOp (ConstantOp $weights),
        (ConstantOp (ExpandTo4DForConv $value)),
        TFL_AF_None),
      $input,
      (ConstantOp $bias),
      $padding, $stride_h, $stride_w),
    [(CanFuseConvOrDepthwiseConv<"false"> $weights, $value),
     (IsNoneType $bias),
     (HasOneUse $output)]>;
}

foreach BinaryOp = [TFL_DivOp, TFL_MulOp] in
  defm : FuseMulOrDivWithConv2dOrDepthwiseConv2d<BinaryOp>;


// This pattern applies when the same quantize/dequantize have been used twice
// with the same scale. We want to remove the redundancy.
// TODO(fengliuai): move this to the sanity check of pre-quantize pass.
def eliminate_dq_q_pairs : Pat<
  (TFL_QuantizeOp (TFL_DequantizeOp $in), $qt),
  (replaceWithValue $in),
  [(NotFromQuantOpOrSameQuantType $in, $qt)]>;




// Checks if the operand has rank == n
class OperandHasRank<int n> : Constraint<
  CPred<"$0.getType().cast<ShapedType>().getRank() == " # n>>;

// Matching HardSwish
def MatchHardSwishPattern1 : Pat<
  (TFL_MulOp
    (TFL_MulOp
     $x, (TFL_AddOp
          $x,
          (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "3.0f">),
          TFL_AF_Relu6),
     TFL_AF_None),
    (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "0.166666666f">),
     TFL_AF_None),
  (TFL_HardSwishOp $x)>;

def MatchHardSwishPattern2 : Pat<
  (TFL_MulOp
    $x,
    (TFL_MulOp
     (TFL_AddOp
      $x,
      (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "3.0f">),
      TFL_AF_Relu6),
     (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "0.166666666f">),
     TFL_AF_None),
     TFL_AF_None),
  (TFL_HardSwishOp $x)>;

// Matching HardSwish with extra FakeQuant. These FakeQuant ops were due to
// incorrect placement in the quantization aware training.
// TODO(b/149735743): We should make the placement automatically.
def MatchHardSwishQuantized : Pat<
  (TFL_MulOp (TFL_DequantizeOp (TFL_QuantizeOp
    (TFL_MulOp
     $x, (TFL_DequantizeOp (TFL_QuantizeOp (TFL_AddOp
          $x,
          (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "3.0f">),
          TFL_AF_Relu6), $qattr2)),
     TFL_AF_None), $qattr1)),
    (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "0.166666666f">),
     TFL_AF_None),
  (TFL_HardSwishOp $x)>;

// Constraint that the attribute value is less than 'n'
class ConstDoubleValueLessThan<string n> : Constraint<
  CPred<"$0.isa<DenseElementsAttr>() && "
  "$0.cast<DenseElementsAttr>().getNumElements() == 1 && "
  "std::abs(*$0.cast<DenseElementsAttr>().getValues<float>().begin()) < "
  # n>>;

def L2NormValidReduceIndex : Constraint<CPred<
  "L2NormalizeReduceAxis($0, $1.cast<DenseElementsAttr>())">>;

// Currently L2Normalization doesn't support activation function
// in TFLite.
// TODO(karimnosseir): Add constraints that the kernel code assumes.
// constraint on axis and depth.
multiclass L2NormalizePatterns<dag FirstOp, dag SecondOp> {
  // This pattern constructs L2NormalizationOp from
  // Mul->Rsqrt->Sum->Square Or
  // Div->sqrt->Sum->Square
  def L2NormalizePattern1#FirstOp#SecondOp : Pat<
                  (FirstOp $x,
                     (SecondOp
                        (TFL_SumOp
                           (TFL_SquareOp:$sq_op $x),
                           (ConstantOp I32ElementsAttr:$axis),
                           $keep_dims)),
                     TFL_AF_None),
           (TFL_L2NormalizationOp $x, TFL_AF_None),
           [(L2NormValidReduceIndex $sq_op, $axis)]>;

  // Below patterns for L2Normalize when there is an Add or Maximum
  // adding or clamping to a small constant scalar.
  def L2NormalizePattern2#FirstOp#SecondOp : Pat<
                    (FirstOp $x,
                     (SecondOp
                      (TFL_AddOp
                       (TFL_SumOp
                        (TFL_SquareOp:$sq_op $x),
                        (ConstantOp I32ElementsAttr:$axis),
                        $keep_dims),
                       (ConstantOp $epsilon), TFL_AF_None)),
           TFL_AF_None),
           (TFL_L2NormalizationOp $x, TFL_AF_None),
           [(L2NormValidReduceIndex $sq_op, $axis),
            (ConstDoubleValueLessThan<"1e-3"> $epsilon)]>;

  def L2NormalizePattern3#FirstOp#SecondOp : Pat<
                    (FirstOp $x,
                     (SecondOp
                      (TFL_MaximumOp
                       (TFL_SumOp
                        (TFL_SquareOp:$sq_op $x),
                        (ConstantOp I32ElementsAttr:$axis),
                        $keep_dims),
                       (ConstantOp $epsilon))),
           TFL_AF_None),
           (TFL_L2NormalizationOp $x, TFL_AF_None),
           [(L2NormValidReduceIndex $sq_op, $axis),
            (ConstDoubleValueLessThan<"1e-3"> $epsilon)]>;

}

foreach L2NormalizePairs = [[TFL_MulOp, TFL_RsqrtOp], [TFL_DivOp, TFL_SqrtOp]]
  in defm : L2NormalizePatterns<L2NormalizePairs[0], L2NormalizePairs[1]>;

//===----------------------------------------------------------------------===//
// Binary ops patterns.
//===----------------------------------------------------------------------===//
def AreBroadcastableTypes : Constraint<CPred<
  "TFL::IsBroadcastableElementsAttrAndType($0.getType(), $1.getType())">>;

def OperandsBroadcastToOutputType : Constraint<CPred<
  "TFL::OperandsBroadcastToOutputType($0.getType(), $1.getType(), "
                                     "$2.getType())">>;

def IsTailOfShape : Constraint<CPred<
  "TFL::IsTailOfShape($0.getType(), $1.getType())">>;

def HaveSameType : Constraint<CPred<"$0.getType(), $1.getType()">>;

// Pattern for skipping Tile if it is mainly for broadcasting and the
// Op is already supporting broadcasting.
multiclass FuseTileBroadcastIntoFollowingBinary<dag BinaryOp> {
  def FuseTileBroadcastToBinaryOp1#BinaryOp : Pat<
    (BinaryOp:$result (TFL_TileOp $input, (ConstantOp $tile)),
     $operand, $act_func),
    (BinaryOp $input, $operand, $act_func),
  [(OperandsBroadcastToOutputType $input, $operand, $result)]>;

  def FuseTileBroadcastToBinaryOp2#BinaryOp : Pat<
    (BinaryOp:$result $operand,
      (TFL_TileOp $input, (ConstantOp $tile)), $act_func),
    (BinaryOp $operand, $input, $act_func),
  [(OperandsBroadcastToOutputType $operand, $input, $result)]>;
}

// Multi-pattern consisting of matching stand-alone op or op followed by relu.
multiclass FusedBinaryActivationFuncOpPat<dag BinaryOp> {
  foreach actFnPair = [[TFL_ReluOp, TFL_AF_Relu],
                       [TFL_Relu6Op, TFL_AF_Relu6],
                       [TFL_Relu1Op, TFL_AF_Relu1]] in {
    def FuseBinaryWithActivation#BinaryOp#actFnPair[0] : Pat<
      (actFnPair[0] (BinaryOp:$binary_out $lhs, $rhs, TFL_AF_None)),
      (BinaryOp $lhs, $rhs, actFnPair[1]),
    [(HasOneUse $binary_out)]>;
  }
}

foreach BinaryOp = [TFL_AddOp, TFL_SubOp, TFL_DivOp, TFL_MulOp] in {
  defm : FuseTileBroadcastIntoFollowingBinary<BinaryOp>;

  // Instantiated FusedBinary patterns for the from-to pairs of ops.
  defm : FusedBinaryActivationFuncOpPat<BinaryOp>;

  // Move binary op before reshape: reshape -> binary => binary -> reshape.
  // This is valid only when the binary operand is constant and the shape is the
  // tail of the other operand and the intermediate result isn't used by other
  // ops.
  // $rhs is required to be the tail shape of $lhs, so after transformation the
  // shape of the binary op result is valid. For example, assume the shapes of
  // $input, $lhs and $rhs are [1600], [1,40,40] and [40x1]. After the
  // transformation, the shape of the binary op result is [40x1600], which
  // couldn't be reshaped to [1,40,40]. `IsTailOfShape` constraint is added to
  // make sure $rhs is the tail shape of $lhs.
  def MoveBinaryOpBeforeReshape#BinaryOp : Pat<
    (BinaryOp (TFL_ReshapeOp:$lhs $input, (ConstantOp:$shape $s)),
      (ConstantOp:$rhs $a), $act_fn),
    (TFL_ReshapeOp (BinaryOp $input, $rhs, $act_fn), $shape),
    // The broadcasting of "BinaryOp" only happens in the lower
    // dimensions, and the higher dimensions are same, so we know the
    // result and input of the "BinaryOp" in the source pattern have
    // the same shape, which is defined by `shape`.
    [(IsTailOfShape $rhs, $lhs),
     (HasOneUse $lhs),
     // The result of the new "BinaryOp" will have the same shape as
     // `input`. In other words, the shape of the `Reshape` op are not
     // changed after the transformation.
     (IsTailOfShape $rhs, $input),
     (HasRankAtMost<5> $input),
     (HasRankAtMost<5> $rhs)]>;
}

foreach BinaryOp = [TFL_FloorDivOp, TFL_FloorModOp, TFL_MinimumOp,
                    TFL_MaximumOp, TFL_LessOp, TFL_LessEqualOp, TFL_GreaterOp,
                    TFL_GreaterEqualOp] in {
  // Move binary op before reshape: reshape -> binary => binary -> reshape.
  // This is valid only when the binary operand is constant and the shape is the
  // tail of the other operand and the intermediate result isn't used by other
  // ops.
  // $rhs is required to be the tail shape of $lhs, so after transformation the
  // shape of the binary op result is valid. For example, assume the shapes of
  // $input, $lhs and $rhs are [1600], [1,40,40] and [40x1]. After the
  // transformation, the shape of the binary op result is [40x1600], which
  // couldn't be reshaped to [1,40,40]. `IsTailOfShape` constraint is added to
  // make sure $rhs is the tail shape of $lhs.
  def MoveBinaryOpBeforeReshape#BinaryOp : Pat<
    (BinaryOp (TFL_ReshapeOp:$lhs $input, (ConstantOp:$shape $s)),
      (ConstantOp:$rhs $a)),
    (TFL_ReshapeOp (BinaryOp $input, $rhs), $shape),
    // The broadcasting of "BinaryOp" only happens in the lower
    // dimensions, and the higher dimensions are same, so we know the
    // result and input of the "BinaryOp" in the source pattern have
    // the same shape, which is defined by `shape`.
    [(IsTailOfShape $rhs, $lhs),
     (HasOneUse $lhs),
     // The result of the new "BinaryOp" will have the same shape as
     // `input`. In other words, the shape of the `Reshape` op are not
     // changed after the transformation.
     (IsTailOfShape $rhs, $input)]>;
}

// Reorder the element-wise value operations and the element move operations,
// such that the value operation happens before move operation.
foreach ValueOp = [TFL_CeilOp, TFL_ExpOp, TFL_FloorOp, TFL_NegOp,
                   TFL_ReluOp, TFL_Relu1Op, TFL_Relu6Op, TFL_RoundOp,
                   TFL_TanhOp, TFL_SqrtOp, TFL_SquareOp] in {
  foreach MoveOp = [TFL_DepthToSpaceOp, TFL_ExpandDimsOp, TFL_SqueezeOp,
                   TFL_ReshapeOp, TFL_TransposeOp] in {
    def ReorderElementwiseAndMoveOperations#ValueOp#MoveOp : Pat<
      (ValueOp:$value (MoveOp:$move $input, $move_def)),
      (MoveOp (ValueOp $input), $move_def),
      [(HasOneUse $move)]>;
  }
}

// Returns shape of a ranked tensor.
// if called without a ranked tensor it will fail.
def GetShape: NativeCodeCall<"GetShape($0)">;

// Returns True if the operand type is RankedTensorType and valid.
def HasValidRankedTensor : Constraint<CPred<
  "$0.getType().isa<RankedTensorType>() && "
  "$0.getType().cast<RankedTensorType>().getNumDynamicDims() <= 1">>;

def ConvertSqueezeToReshape : Pat<
  (TFL_SqueezeOp:$squeeze_op $input, $squeeze_dims),
  (TFL_ReshapeOp $input, (ConstantOp (GetShape $squeeze_op))),
  [(HasValidRankedTensor $squeeze_op)]>;

// Convert expand_dims to reshape if possible.
def ConvertExpandDimsToReshape : Pat<
  (TFL_ExpandDimsOp:$expand_dims_op $input, $dim),
  (TFL_ReshapeOp $input, (ConstantOp (GetShape $expand_dims_op))),
  [(AnyStaticShapeTensor $expand_dims_op)]>;

class FloatValueEquals<string val> : Constraint<CPred<
  "$0.isa<DenseFPElementsAttr>() && "
  "llvm::all_of($0.cast<DenseElementsAttr>().getFloatValues(), "
  "[](const APFloat& f) { return f.isExactlyValue(" # val # "); })">>;

// ReLU patterns
def MatchReluPattern : Pat<
  (TFL_MaximumOp $input, (ConstantOp $Zero)),
  (TFL_ReluOp $input),
  [(FloatValueEquals<"0"> $Zero)]>;

def MatchRelu1Pattern1 : Pat<
  (TFL_MinimumOp (TFL_MaximumOp $input, (ConstantOp $NegOne)),
    (ConstantOp $One)),
  (TFL_Relu1Op $input),
  [(FloatValueEquals<"-1"> $NegOne), (FloatValueEquals<"1"> $One)]>;

def MatchRelu1Pattern2 : Pat<
  (TFL_MaximumOp (TFL_MinimumOp $input, (ConstantOp $One)),
    (ConstantOp $NegOne)),
  (TFL_Relu1Op $input),
  [(FloatValueEquals<"-1"> $NegOne), (FloatValueEquals<"1"> $One)]>;

def MatchLeakyRelu : Pat<
  (TFL_MaximumOp
    (TFL_MulOp:$mul_out $x,
     (ConstantOp F32ElementsAttr:$alpha), TFL_AF_None),
    $x),
  (TFL_LeakyReluOp $x, ExtractSingleElementAsFloat:$alpha),
  [(ConstDoubleValueLessThan<"1"> $alpha),
   (HasOneUse $mul_out)]>;

def RemoveTrivialCast : Pat<(TFL_CastOp:$output $input),
                            (replaceWithValue $input),
                            [(SameElementType $input, $output)]>;

// Checks if the operand0's rank is one less than operand1's rank.
def PReluAlphaRankCheck : Constraint<
  CPred<"$0.getType().cast<ShapedType>().getRank() == "
  "$1.getType().cast<ShapedType>().getRank() - 1">>;

// PReLU pattern from Keras:
// f(x) = Relu(x) + (-alpha * Relu(-x))
def MatchPRelu : Pat<
  (TFL_AddOp
   (TFL_ReluOp:$relu_out $x),
   (TFL_MulOp:$mul_out
    (TFL_ReluOp (TFL_NegOp:$input_neg_out $x)),
    $neg_alpha,
    TFL_AF_None),
   TFL_AF_None),
  (TFL_PReluOp $x, (TFL_NegOp $neg_alpha)),
  [(PReluAlphaRankCheck $neg_alpha, $x),
   (HasOneUse $relu_out),
   (HasOneUse $mul_out),
   (HasOneUse $input_neg_out)]>;

// The constant folding in this pass might produce constant in the tf dialect.
// This rule is to legalize these constant to the tfl dialect.
def LegalizeConstOp : Pat<
  (TF_ConstOp ElementsAttr:$value), (TFL_ConstOp $value)>;

// Reorders adds to allow constant folding.
// Add --> Add $input, $constantA
//    \--> $constantB
// To
// Add --> $input
//    \--> Add ($constantA, $constantB)
foreach ActFun = [TFL_AF_Relu, TFL_AF_Relu6, TFL_AF_Relu1, TFL_AF_None] in {
  def ReorderAddToAllowConstFold_ActFunc_#ActFun : Pat<
    (TFL_AddOp
     (TFL_AddOp:$first_output $input, (ConstantOp $a), TFL_AF_None),
     (ConstantOp $b), ActFun),
    (TFL_AddOp $input,
     (TFL_AddOp (ConstantOp $a), (ConstantOp $b), TFL_AF_None),
     ActFun),
    [(HasOneUse $first_output)]>;
}

// We can eliminate Relu from Relu(SquaredDifference(x, y)),
// since the result of SquaredDifference is always non-negative.
// TFLite interpreter doesn't support Relu+int32 for now. So the test cases
// are failing without the following pattern to optimize Relu away fixes
// the problem.
def OptimizeReluSquaredDifference : Pat<
  (TFL_ReluOp (TFL_SquaredDifferenceOp $l, $r)),
  (TFL_SquaredDifferenceOp $l, $r)>;

// Optimize X^1 o X
def OptimizePow1ToIdentity : Pat<
  (TFL_PowOp $input,
    (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "1.0f">)),
  (replaceWithValue $input)>;

// Optimize X^2 to X*X
def OptimizePow2ToSquare : Pat<
  (TFL_PowOp $input,
    (ConstantOp ConstantAttr<RankedF32ElementsAttr<[]>, "2.0f">)),
  (TFL_MulOp $input, $input, TFL_AF_None)>;

def CanOptimizeIdentityGatherNdOrScatterNdOp : Constraint<CPred<
  "TFL::CanOptimizeIdentityGatherNdOrScatterNdOp("
  "$0, $1.cast<DenseIntElementsAttr>())">>;

def OptimizeIdentityGatherNdOp : Pat<
  (TFL_GatherNdOp $params, (ConstantOp I32ElementsAttr: $indices)),
  (replaceWithValue $params),
  [(CanOptimizeIdentityGatherNdOrScatterNdOp $params, $indices)]>;

def OptimizeIdentityScatterNdOp : Pat<
  (TFL_ScatterNdOp (ConstantOp I32ElementsAttr: $indices), $params, $ignored),
  (replaceWithValue $params),
  [(CanOptimizeIdentityGatherNdOrScatterNdOp $params, $indices)]>;

def ShapeMatchesReduceWithKeepAxes : Constraint<CPred<
  "ShapeMatchesReduceWithKeepAxes($0, $1, $2)">>;

// Fold reshapes re-inserting reduced dimensions into the results of a reduction
// with `keep_dims=false` by changing it to one using `keep_dims=true`.
foreach ReduceOp = [TFL_ReduceMaxOp, TFL_ReduceMinOp, TFL_ReduceProdOp,
                    TFL_SumOp] in {
  def FoldReshapeTo#ReduceOp : Pat<
    (TFL_ReshapeOp
      (ReduceOp:$reduce $input, (ConstantOp I32ElementsAttr: $axes),
                        ConstBoolAttrFalse),
      (ConstantOp I32ElementsAttr: $shape)),
    (ReduceOp $input, (ConstantOp $axes), ConstBoolAttrTrue),
    [(ShapeMatchesReduceWithKeepAxes $input, $axes, $shape),
     (HasOneUse $reduce)]>;
}


def IsSame : Constraint<CPred<"$0 == $1">>;
def HasTwoUse : Constraint<CPred<
  "std::distance($0.use_begin(), $0.use_end()) == 2">>;
def AxesIsLastDimension : Constraint<CPred<
  "$0.cast<DenseIntElementsAttr>().getNumElements() == 1 && "
  "$0.cast<DenseIntElementsAttr>().getValue<APInt>({0}) == "
  "$1.getType().cast<ShapedType>().getRank() - 1">>;

// Convert exp(x)/sum(exp(x)) into softmax.
def OptimizeToSoftmax : Pat<
  (TFL_DivOp (TFL_ExpOp:$exp $input),
             (TFL_SumOp:$sum $sum_input, (ConstantOp I32ElementsAttr: $axes),
                             ConstBoolAttrTrue), TFL_AF_None),
  (TFL_SoftmaxOp $input, ConstF32Attr<"1.0">),
  [(IsSame $exp, $sum_input),
   (AxesIsLastDimension $axes, $sum_input),
   (HasTwoUse $exp),
   (HasOneUse $sum)]>;

// Convert softmax(x-max(x)) into softmax(x) as the softmax op already deals
// with the max normalization.
def FoldNormalizationIntoSoftmax : Pat<
  (TFL_SoftmaxOp
    (TFL_SubOp:$sub $input,
      (TFL_ReduceMaxOp:$max $max_input, (ConstantOp I32ElementsAttr: $axes),
                            ConstBoolAttrTrue),
    TFL_AF_None),
    $beta),
  (TFL_SoftmaxOp $input, $beta),
  [(IsSame $input, $max_input),
   (AxesIsLastDimension $axes, $max_input),
   (HasOneUse $sub),
   (HasOneUse $max)]>;
