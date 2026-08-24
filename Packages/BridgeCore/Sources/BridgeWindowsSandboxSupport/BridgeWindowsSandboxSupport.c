#define _WIN32_WINNT 0x0A00

#include "BridgeWindowsSandboxSupport.h"

#include <Aclapi.h>
#include <Sddl.h>
#include <UserEnv.h>

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Userenv.lib")

static HRESULT bridge_app_container_sid(PCWSTR profile_name, PSID *sid) {
  HRESULT result = CreateAppContainerProfile(
    profile_name,
    profile_name,
    L"Codex Bridge Direct command isolation",
    NULL,
    0,
    sid
  );
  if (result == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
    return DeriveAppContainerSidFromAppContainerName(profile_name, sid);
  }
  return result;
}

static DWORD bridge_grant_project_access(PCWSTR path, PSID app_container_sid) {
  PSECURITY_DESCRIPTOR descriptor = NULL;
  PACL existing_acl = NULL;
  DWORD result = GetNamedSecurityInfoW(
    (PWSTR)path,
    SE_FILE_OBJECT,
    DACL_SECURITY_INFORMATION,
    NULL,
    NULL,
    &existing_acl,
    NULL,
    &descriptor
  );
  if (result != ERROR_SUCCESS) {
    return result;
  }

  EXPLICIT_ACCESSW access = {0};
  access.grfAccessPermissions = FILE_GENERIC_READ | FILE_GENERIC_WRITE |
    FILE_GENERIC_EXECUTE | DELETE;
  access.grfAccessMode = GRANT_ACCESS;
  access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  access.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN;
  access.Trustee.ptstrName = (PWSTR)app_container_sid;

  PACL updated_acl = NULL;
  result = SetEntriesInAclW(1, &access, existing_acl, &updated_acl);
  if (result == ERROR_SUCCESS) {
    result = SetNamedSecurityInfoW(
      (PWSTR)path,
      SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,
      NULL,
      NULL,
      updated_acl,
      NULL
    );
  }

  if (updated_acl != NULL) {
    LocalFree(updated_acl);
  }
  if (descriptor != NULL) {
    LocalFree(descriptor);
  }
  return result;
}

static BOOL bridge_internet_client_sid(PSID sid, DWORD *sid_size) {
  return CreateWellKnownSid(
    WinCapabilityInternetClientSid,
    NULL,
    sid,
    sid_size
  );
}

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
) {
  if (profile_name == NULL || executable_path == NULL || command_line == NULL ||
      project_root == NULL || process_information == NULL || error_code == NULL) {
    if (error_code != NULL) {
      *error_code = ERROR_INVALID_PARAMETER;
    }
    return FALSE;
  }

  PSID app_container_sid = NULL;
  HRESULT profile_result = bridge_app_container_sid(profile_name, &app_container_sid);
  if (FAILED(profile_result)) {
    *error_code = (DWORD)profile_result;
    return FALSE;
  }

  DWORD acl_result = bridge_grant_project_access(project_root, app_container_sid);
  if (acl_result != ERROR_SUCCESS) {
    FreeSid(app_container_sid);
    *error_code = acl_result;
    return FALSE;
  }

  BYTE internet_sid_storage[SECURITY_MAX_SID_SIZE] = {0};
  DWORD internet_sid_size = sizeof(internet_sid_storage);
  SID_AND_ATTRIBUTES internet_capability = {0};
  if (allow_network) {
    if (!bridge_internet_client_sid(internet_sid_storage, &internet_sid_size)) {
      DWORD error = GetLastError();
      FreeSid(app_container_sid);
      *error_code = error;
      return FALSE;
    }
    internet_capability.Sid = internet_sid_storage;
    internet_capability.Attributes = SE_GROUP_ENABLED;
  }

  SECURITY_CAPABILITIES capabilities = {0};
  capabilities.AppContainerSid = app_container_sid;
  capabilities.Capabilities = allow_network ? &internet_capability : NULL;
  capabilities.CapabilityCount = allow_network ? 1 : 0;

  HANDLE inherited_handles[] = {standard_input, standard_output, standard_error};
  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(NULL, 2, 0, &attribute_bytes);
  LPPROC_THREAD_ATTRIBUTE_LIST attributes =
    (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_bytes);
  if (attributes == NULL) {
    FreeSid(app_container_sid);
    *error_code = ERROR_NOT_ENOUGH_MEMORY;
    return FALSE;
  }

  BOOL initialized = InitializeProcThreadAttributeList(
    attributes,
    2,
    0,
    &attribute_bytes
  );
  BOOL handles_updated = initialized && UpdateProcThreadAttribute(
    attributes,
    0,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
    inherited_handles,
    sizeof(inherited_handles),
    NULL,
    NULL
  );
  BOOL capabilities_updated = handles_updated && UpdateProcThreadAttribute(
    attributes,
    0,
    PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES,
    &capabilities,
    sizeof(capabilities),
    NULL,
    NULL
  );
  if (!capabilities_updated) {
    DWORD error = GetLastError();
    if (initialized) {
      DeleteProcThreadAttributeList(attributes);
    }
    HeapFree(GetProcessHeap(), 0, attributes);
    FreeSid(app_container_sid);
    *error_code = error;
    return FALSE;
  }

  STARTUPINFOEXW startup = {0};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.StartupInfo.wShowWindow = SW_HIDE;
  startup.StartupInfo.hStdInput = standard_input;
  startup.StartupInfo.hStdOutput = standard_output;
  startup.StartupInfo.hStdError = standard_error;
  startup.lpAttributeList = attributes;

  BOOL created = CreateProcessW(
    executable_path,
    command_line,
    NULL,
    NULL,
    TRUE,
    creation_flags | EXTENDED_STARTUPINFO_PRESENT,
    environment,
    working_directory,
    &startup.StartupInfo,
    process_information
  );
  DWORD create_error = created ? ERROR_SUCCESS : GetLastError();

  DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  FreeSid(app_container_sid);
  *error_code = create_error;
  return created;
}

BOOL bridge_current_process_is_app_container(void) {
  HANDLE token = NULL;
  DWORD value = 0;
  DWORD size = 0;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return FALSE;
  }
  BOOL result = GetTokenInformation(
    token,
    TokenIsAppContainer,
    &value,
    sizeof(value),
    &size
  );
  CloseHandle(token);
  return result && value != 0;
}

BOOL bridge_current_process_has_internet_client_capability(void) {
  HANDLE token = NULL;
  BYTE internet_sid_storage[SECURITY_MAX_SID_SIZE] = {0};
  DWORD internet_sid_size = sizeof(internet_sid_storage);
  if (!bridge_internet_client_sid(internet_sid_storage, &internet_sid_size) ||
      !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return FALSE;
  }

  DWORD required = 0;
  GetTokenInformation(token, TokenCapabilities, NULL, 0, &required);
  if (required == 0) {
    CloseHandle(token);
    return FALSE;
  }
  PTOKEN_GROUPS groups = (PTOKEN_GROUPS)HeapAlloc(GetProcessHeap(), 0, required);
  if (groups == NULL) {
    CloseHandle(token);
    return FALSE;
  }
  BOOL loaded = GetTokenInformation(
    token,
    TokenCapabilities,
    groups,
    required,
    &required
  );
  BOOL found = FALSE;
  if (loaded) {
    for (DWORD index = 0; index < groups->GroupCount; index++) {
      if (EqualSid(groups->Groups[index].Sid, internet_sid_storage)) {
        found = TRUE;
        break;
      }
    }
  }
  HeapFree(GetProcessHeap(), 0, groups);
  CloseHandle(token);
  return found;
}
