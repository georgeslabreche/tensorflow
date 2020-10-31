#include "tensorflow/lite/c/c_api.h"
#include "tensorflow/lite/c/c_api_experimental.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/c/builtin_op_data.h"
#include "tensorflow/lite/c/ujpeg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/**
 * TODO:
 *  [ ] JPEG Decoder error handling.
 *  [ ] TFLite return error code.
 *  [ ] Input mean and input STD as arguments.
 *  [ ] Image resizing.
 *  [ ] Classification CSV report.
 *  [ ] Logging.
 *  [ ] Move images toGround.
 *  [ ] Batch image processing.
 */ 

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

char *getBasename(char const *path)
{
    char *s = strrchr(path, '/');
    if (!s)
    {
      return strdup(path);
    }  
    else
    {
       return strdup(s + 1);
    }
       
}

/**
 * The main function.
 * args 1 is the image filename.
 * args 2 is the model filename.
 */
int main(int argc, char *argv[]) 
{
    const char* imageFilePath = argv[1];
    const char* modelFilePath = argv[2];

    TfLiteStatus tflStatus;

    // Create JPEG image object.
    ujImage img = ujCreate();

    // Decode the JPEG file.
    ujDecodeFile(img, imageFilePath);

    // Check if decoding was successful.
    if(ujIsValid(img) == 0){
        printf("Error decoding image.\n");
        return 1;
    }
    
    // There will always be 3 channels.
    int channel = 3;

    // Height will always be 224, no need for resizing.
    int height = ujGetHeight(img);

    // Width will always be 224, no need for resizing.
    int width = ujGetWidth(img);

    // The image size is channel * height * width.
    int imageSize = ujGetImageSize(img);

    // Fetch RGB data from the decoded JPEG image input file.
    uint8_t* pImage = (uint8_t*)ujGetImage(img, NULL);

    // The array that will collect the JPEG's RGB values.
    float imageDataBuffer[imageSize];

    // RGB range is 0-255. Scale it to 0-1.
    for(int i = 0; i < imageSize; i++)
    {
        imageDataBuffer[i] = (float)pImage[i] / 255.0;
    }

    // Load model.
    TfLiteModel* model = TfLiteModelCreateFromFile(modelFilePath);

    // Create the interpreter.
    TfLiteInterpreter* interpreter = TfLiteInterpreterCreate(model, NULL);

    // Allocate tensors.
    tflStatus = TfLiteInterpreterAllocateTensors(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error allocating tensors.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }
    
    int inputDims[4] = {1, 224, 224, 3};
    tflStatus = TfLiteInterpreterResizeInputTensor(interpreter, 0, inputDims, 4);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error resizing tensor.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }

    tflStatus = TfLiteInterpreterAllocateTensors(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error allocating tensors after resize.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }

    // The input tensor.
    TfLiteTensor* inputTensor = TfLiteInterpreterGetInputTensor(interpreter, 0);

    // Copy the JPEG image data into into the input tensor.
    tflStatus = TfLiteTensorCopyFromBuffer(inputTensor, imageDataBuffer, imageSize * sizeof(float));
    
    // Log and exit in case of error.
    // FIXME: Error occurs here.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error copying input from buffer.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }

    // Invoke interpreter.
    tflStatus = TfLiteInterpreterInvoke(interpreter);

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error invoking interpreter.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }

    // Extract the output tensor data.
    const TfLiteTensor* outputTensor = TfLiteInterpreterGetOutputTensor(interpreter, 0);

    // There are three possible labels. Size the output accordingly.
    float output[3];
    tflStatus = TfLiteTensorCopyToBuffer(outputTensor, output, 3 * sizeof(float));

    // Log and exit in case of error.
    if(tflStatus != kTfLiteOk)
    {
      printf("Error copying output to buffer.\n");
      disposeTfLiteObjects(model, interpreter);
      return 1;
    }

    // Print out classification result.
    printf("Predictions for %s - [bad: %f, earth: %f, edge: %f]\n", getBasename(imageFilePath), output[0], output[1], output[2]); 

    // Dispose of the TensorFlow objects.
    disposeTfLiteObjects(model, interpreter);
    
    // Dispoice of the image object.
    ujFree(img);
    
    return 0;
}
