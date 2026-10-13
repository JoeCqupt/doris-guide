#include <omp.h>
#include <stdio.h>
int main(void) {
    int count = 0;
    #pragma omp parallel num_threads(2) reduction(+:count)
    count += 1;
    printf("OpenMP workers=%d\n", count);
    return count == 2 ? 0 : 1;
}
