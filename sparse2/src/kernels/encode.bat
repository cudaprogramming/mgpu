nvcc --cubin -Xptxas=-v -arch=compute_20 -code=sm_20 -D MAT_TYPE_FLOAT -o ../cubin/matrixencode_float.cubin matrixencode.cu
cuobjdump -sass ../cubin/matrixencode_float.cubin > ../isa/matrixencode_float.isa