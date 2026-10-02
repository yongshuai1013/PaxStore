#ifndef IDEVICE_H
#define IDEVICE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

// 不透明句柄
typedef struct IdevicePairingFile IdevicePairingFile;
typedef struct IdeviceProviderHandle IdeviceProviderHandle;
typedef struct AfcClientHandle AfcClientHandle;
typedef struct AfcFileHandle AfcFileHandle;

// 錯誤
typedef struct {
    int32_t code;
    int32_t sub_code;
    const char* message;
} IdeviceFfiError;
void idevice_error_free(IdeviceFfiError* err);

// AFC 打開模式
typedef enum {
    AfcRdOnly = 1,
    AfcRw = 2,
    AfcWrOnly = 3,
    AfcWr = 4,
    AfcAppend = 5,
    AfcRdAppend = 6
} AfcFopenMode;

// 配對檔
IdeviceFfiError* idevice_pairing_file_from_bytes(
    const uint8_t* data, size_t size,
    IdevicePairingFile** pairing_file);
void idevice_pairing_file_free(IdevicePairingFile* pairing_file);

// TCP provider（pairing_file 會被 consume）
IdeviceFfiError* idevice_tcp_provider_new(
    const struct sockaddr* addr,
    IdevicePairingFile* pairing_file,
    const char* label,
    IdeviceProviderHandle** provider);
void idevice_provider_free(IdeviceProviderHandle* provider);

// AFC
IdeviceFfiError* afc_client_connect(
    IdeviceProviderHandle* provider,
    AfcClientHandle** client);
void afc_client_free(AfcClientHandle* handle);

IdeviceFfiError* afc_file_open(
    AfcClientHandle* client, const char* path,
    AfcFopenMode mode, AfcFileHandle** handle);
IdeviceFfiError* afc_file_write(
    AfcFileHandle* handle, const uint8_t* data, size_t length);
IdeviceFfiError* afc_file_close(AfcFileHandle* handle);

#ifdef __cplusplus
}
#endif

#endif
