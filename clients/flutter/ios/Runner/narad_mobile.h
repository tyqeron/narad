#ifndef NARAD_MOBILE_H
#define NARAD_MOBILE_H
#ifdef __cplusplus
extern "C" {
#endif
char *narad_mobile_call(const char *input);
void narad_mobile_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
