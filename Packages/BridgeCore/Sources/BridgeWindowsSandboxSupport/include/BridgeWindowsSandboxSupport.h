#ifndef BRIDGE_WINDOWS_SANDBOX_SUPPORT_H
#define BRIDGE_WINDOWS_SANDBOX_SUPPORT_H

#include <WinSock2.h>
#include <Windows.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL bridge_create_app_container_process(
  PCWSTR profile_name,
  PCWSTR executable_path,
  PWSTR command_line,
  PCWSTR working_directory,
  LPVOID environment,
  HANDLE standard_input,
  HANDLE standard_output,
  HANDLE standard_error,
  PCWSTR project_root,
  BOOL allow_network,
  DWORD creation_flags,
  PROCESS_INFORMATION *process_information,
  DWORD *error_code
);

BOOL bridge_current_process_is_app_container(void);
BOOL bridge_current_process_has_internet_client_capability(void);
UINT_PTR bridge_create_loopback_listener(USHORT *port);
void bridge_close_socket(UINT_PTR socket_value);
BOOL bridge_loopback_connect(USHORT port);

#ifdef __cplusplus
}
#endif

#endif
