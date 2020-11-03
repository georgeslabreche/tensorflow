#include "tensorflow/lite/c/c_api.h"
#include "tensorflow/lite/c/c_api_experimental.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/c/builtin_op_data.h"
#include "tensorflow/lite/c/ujpeg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef enum {
    UJ_INVALID_DECODING             = 10, // Error decoding the image.
    TF_ALLOCATE_TENSOR              = 11, // Error allocating tensors.
    TF_RESIZE_TENSOR                = 12, // Error resizing tensor.
    TF_ALLOCATE_TENSOR_AFTER_RESIZE = 13, // Error allocating tensors after resize.
    TF_COPY_BUFFER_TO_INPUT         = 14, // Error copying input from buffer.
    TF_INVOKE_INTERPRETER           = 15, // Error invoking interpreter.
    TF_COPY_OUTOUT_TO_BUFFER        = 16, // Error copying output to buffer.
    FP_OPEN_LABELS_FILE             = 17  // Unable to open labels file
} errorCode;

// Dispose of the model and interpreter objects.
int disposeTfLiteObjects(TfLiteModel* pModel, TfLiteInterpreter* pInterpreter)
{
    if(pModel != NULL)
    {
      TfLiteModelDelete(pModel);
    }

    if(pInterpreter)
    {
      TfLiteInterpreterDelete(pInterpreter);
    }
}

/**
 * The main function.
 * argv[1] is the image filename.
 * argv[2] is the model filename.
 * argv[3] is the class labels filename.
 * argv[4] is the image input height.
 * argv[5] is the image input width.
 * argv[6] is the input mean. Scale pixel values to this mean.
 * argv[7] is the input standard deviation. Scale pixel values to this standard deviation.
 */
int main(int argc, char *argv[])
{
    // Input parameters.
    const char* imageFilePath = argv[1];
    const char* modelFilePath = argv[2];
    const char* labelsFilePath = argv[3];

    int inputImageHeight;
    sscanf(argv[4], "%d", &inputImageHeight);

    int inputImageWidth;
    sscanf(argv[5], "%d", &inputImageWidth);

    float inputMean;
    sscanf(argv[6], "%f", &inputMean);

    float inputStandardDeviation;
    sscanf(argv[7], "%f", &inputStandardDeviation);

    // There will always be 3 channels.
    int channel = 3;

    // Return codes for error handling.
    TfLiteStatus tflStatus;
    ujResult ujRes;

    /**
     * STEP 1.
     * Decode the JPEG image input to produce an RGB pixel values buffer array.
     * Use the NanoJPEG library.
     */ 

    // Create JPEG image object.
    ujImage img = ujCreate();

    // Decode the JPEG file.
    ujDecodeFile(img, imageFilePath);

    // Exit program with error code if previous JPEG processing operation resulted in an error.
    ujRes = ujGetError();
    if(ujRes != UJ_OK)
    {
      return ujRes;
    }
    
    // Check if decoding was successful.
    if(ujIsValid(img) == 0)
    {
        return UJ_INVALID_DECODING;
    }

    // The input image is assumed to have its height pixel size equal to the inputImageHeight parameter so no need for resizing.
    // FIXME: Don't assume. Check and resize if necessary. Will have to use a lightweight image manipulation library.
    int height = ujGetHeight(img);

    // Exit program with error code if previous JPEG processing operation resulted in an error.
    ujRes = ujGetError();
    if(ujRes != UJ_OK)
    {
      return ujRes;
    }

    // The input image is assumed to have its width pixel size equal to the inputImageWidth parameter so no need for resizing.
    // FIXME: Don't assume. Check and resize if necessary. Will have to use a lightweight image manipulation library.
    int width = ujGetWidth(img);

    // Exit program with error code if previous JPEG processing operation resulted in an error.
    ujRes = ujGetError();
    if(ujRes != UJ_OK)
    {
      return ujRes;
    }

    // The image size is channel * height * width.
    int imageSize = ujGetImageSize(img);

    // Exit program with error code if previous JPEG processing operation resulted in an error.
    ujRes = ujGetError();
    if(ujRes != UJ_OK)
    {
      return ujRes;
    }

    // Fetch RGB data from the decoded JPEG image input file.
    uint8_t* pImage = (uint8_t*)ujGetImage(img, NULL);

    // Exit program with error code if previous JPEG processing operation resulted in an error.
    ujRes = ujGetError();
    if(ujRes != UJ_OK)
    {
      return ujRes;
    }

    // The array that will collect the JPEG's RGB values.
    float imageDataBuffer[imageSize];

    // RGB range is 0-255. Rescale it based on given input mean and standard deviation.
    // e.g. with input mean 0 and inpt std 255 the 0-255 RGB range is rescaled to 0-1.
    for(int i = 0; i < imageSize; i++)
    {
        imageDataBuffer[i] = ((float)pImage[i] - inputMean) / inputStandardDeviation;
    }

    /**
     * STEP 2.
     * Read the labels file to count the number of labels.
     */

    // Count the nunber of image class labels included in the labels file.
    int label_counter = 0;

    // Open labels file to fetch and count labels listed in that file.
    FILE *fpLabels = fopen(labelsFilePath, "r");

    // Check that labels file was opened.
    if(fpLabels == NULL) 
    {
      return FP_OPEN_LABELS_FILE;
    }

    // Count the number of labels in the labels file.
    int labelsCount = 0;
    while(!feof(fpLabels))
    {
        char ch = fgetc(fpLabels);
        if(ch == '\n')
        {
          labelsCount++;
        }
    }

    // Rewind labels file pointer back to the begining of the file in order to prep for more file reading later.
    fseek(fpLabels, 0, SEEK_SET);

    /**
     * STEP 3.
     * Load the predition model.
     * Prepare the image tensor input.
     * Set the input dimension.
     */

    // Load model.
    TfLiteModel* model = TfLiteModelCreateFromFile(modelFilePath);

    // Create the interpreter.
    TfLiteInterpreter* interpreter = TfLiteInterpreterCreate(model, NULL);

    // Allocate tensors.
    tflStatus = TfLiteInterpreterAllocateTensors(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      disposeTfLiteObjects(model, interpreter);
      return TF_ALLOCATE_TENSOR;
    }
    
    int inputDims[4] = {1, inputImageHeight, inputImageWidth, channel};
    tflStatus = TfLiteInterpreterResizeInputTensor(interpreter, 0, inputDims, 4);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      disposeTfLiteObjects(model, interpreter);
      return TF_RESIZE_TENSOR;
    }

    tflStatus = TfLiteInterpreterAllocateTensors(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      disposeTfLiteObjects(model, interpreter);
      return TF_ALLOCATE_TENSOR_AFTER_RESIZE;
    }

    /**
     * STEP 4.
     * Invoke the TensorFlow intepreter given the input and the model.
     */

    // The input tensor.
    TfLiteTensor* inputTensor = TfLiteInterpreterGetInputTensor(interpreter, 0);

    // Copy the JPEG image data into into the input tensor.
    tflStatus = TfLiteTensorCopyFromBuffer(inputTensor, imageDataBuffer, imageSize * sizeof(float));
    
    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      disposeTfLiteObjects(model, interpreter);
      return TF_COPY_BUFFER_TO_INPUT;
    }

    // Invoke interpreter.
    tflStatus = TfLiteInterpreterInvoke(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      disposeTfLiteObjects(model, interpreter);
      return TF_INVOKE_INTERPRETER;
    }

    /**
     * STEP 5.
     * Get the prediction output from feeding the image into the prediction model.
     */

    // Extract the output tensor data.
    const TfLiteTensor* outputTensor = TfLiteInterpreterGetOutputTensor(interpreter, 0);

    // Size the model output based on the number of labels counted in the labels file.
    float output[labelsCount];
    tflStatus = TfLiteTensorCopyToBuffer(outputTensor, output, labelsCount * sizeof(float));

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      // Close file pointer to labels file.
      fclose(fpLabels);

      // Dispose of the TensorFlow Lite objects.
      disposeTfLiteObjects(model, interpreter);

      // Return error code.
      return TF_COPY_OUTOUT_TO_BUFFER;
    }

    /**
     * STEP 6.
     * Read the labels file and write into stdout a JSON object string of the image classification result.
     * The JSON object will have labels as key and prediction confidences as values.
     */

    // The label string buffer.
    char labelBuffer[128]; 

    // The output index for the model output array.
    int outputIndex = 0;

    // Start writing the JSON object string into stdout.
    printf("{");

    // Write the <label, prediction> key value pairs into stdout.
    while(fgets(labelBuffer, sizeof(labelBuffer), fpLabels) != NULL) 
    {
      // Remove the last character of the label string, it's a new line character.
      labelBuffer[strlen(labelBuffer)-1] = '\0';

      // Print to stdout the prediction key value pair for the current output/label.
      if(outputIndex < (labelsCount-1))
      {
        // We expect another key value pair after this so include a comma.
        printf("\"%s\": %f, ", labelBuffer, output[outputIndex]);
      }
      else
      {
        // This is the last key value pair, don't include a comma.
        printf("\"%s\": %f", labelBuffer, output[outputIndex]);
      }

      // Incremenet output index for the next iteration.
      outputIndex++;
    }

    // Finish writing the JSON object string into stdout.
    printf("}");

    // Close file pointer to labels file.
    fclose(fpLabels);

    /**
     * STEP 7.
     * Cleanup.
     * Dispose of some objects.
     */

    // Dispose of the TensorFlow objects.
    disposeTfLiteObjects(model, interpreter);
    
    // Dispose of the image object.
    ujFree(img);
    
    // Program return code.
    return 0;
}
