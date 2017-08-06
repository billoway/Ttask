#ifndef mtask_ENV_H
#define mtask_ENV_H

const char * mtask_getenv(const char *key);

void mtask_setenv(const char *key, const char *value);

void mtask_env_init();

#endif
