#ifndef KEYTRAIL_RUST_H
#define KEYTRAIL_RUST_H
void *keytrail_open(const char *path, char **error_out);
char *keytrail_request(void *handle, const char *json);
void keytrail_string_free(char *value);
void keytrail_close(void *handle);
#endif
