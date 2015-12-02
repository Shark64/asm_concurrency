%include "os_dependent_stuff.asm"

  ; Initialize constants.
  xor ebx, ebx
  mov r12d,65537                ; Exponent to modular-exponentiate with
  lea r15d, [ebx+NPROCS]        ; Number of worker processes to fork.
  mov bl, 235                   ; Modulus to modular-exponentiate with
  mov r14d, (SIZE+1)*8            ; Size of shared memory; reserving first
                                 ; 64 bits for bookkeeping

  ; Check for command-line argument.
  xor eax, eax
  mov al, 1
  cmp rax qword [rsp]
  je map_anon

open_file:
  ; We have a file specified on the command line, so open() it.
  mov al, SYSCALL_OPEN          ; set up open()
  mov rdi, [rsp+2*8]               ; filename from command line
  lea esi, [rax+0x40]               ;O_RDWR|O_CREAT read/write mode; create if necessary
  mov edx, 660o                    ; `chmod`-mode of file to create (octal)
  syscall                        ; do open() system call
  mov r13, rax                   ; preserve file descriptor in r13
  mov rdi, rax                     ; file descriptor
  xor eax, eax
  mov al, SYSCALL_FTRUNCATE     ; set up ftruncate() to adjust file size
  mov esi, r14d                 ; desired file size
  syscall                        ; do ftruncate() system call
  mov r8,  r13
  mov r10, MAP_SHARED
  jmp mmap

  ; Ask the kernel for a shared memory mapping.
map_anon:
  mov r10, MAP_SHARED|MAP_ANON     ; MAP_ANON means not backed by a file
  or r8,  -1                      ; thus our file descriptor is -1
mmap:
  xor r9d,r9d                      ; and there's no file offset in either case.
  xor edi,edi                   ; no pre-specified memory location.
  lea eax, [rdi+SYSCALL_MMAP]          ; set up mmap()
  lea edx, [rdi+0x9]              ; 0x9 = read/write mapping
  mov esi, r14d                     ; Length of the mapping in bytes.
  syscall                        ; do mmap() system call.
  test rax, rax                  ; Return value will be in rax.
  js error                       ; If it's negative, that's trouble.
  mov r10, rax                   ; Otherwise, we have our memory region [r10].

  lock add [rax], r15            ; Add NPROCS to the file's first machine word.
                                 ; We'll use it to track the # of still-running
                                 ; worker processes.

  ; Next, fork NPROCS processes.
fork:
  xor eax, eax
  mov al, SYSCALL_FORK
  syscall
%ifidn __OUTPUT_FORMAT__,elf64     ; (This means we're running on Linux)
  test eax, eax                  ; We're a child iff return value of fork()==0.
  jz child
%elifidn __OUTPUT_FORMAT__,macho64 ; (This means we're running on OSX)
  test edx, edx                  ; Apple...you're not supposed to touch rdx here
  jnz child                      ; Apple, what
%endif
  dec r15
  jnz fork
parent:
  xor eax, eax
  pause
  cmp rax, [r10]
  jnz parent                     ; Wait for [rbp], the worker count, to be zero
%ifndef NOPRINT
  lea rbx, [r10+r14]             ; rbx marks the end of the [r10] region
  add r10, 8                     ; Don't print the first 8 bytes
print_loop:
  mov rdi, unsigned_int          ; Set printf format string
  xor eax, eax                   ; Clear rax (number of non-int args to printf)
  movzx edx, [r10]               ; load a single byte into its low byte
  mov esi, edx                   ; Transfer to the first-printf-arg register
  and rsp, ~(0xf)                ; 16-byte-align stack pointer
  call printf                    ; Do printf
  inc r10                        ; Increment data pointer
  cmp r10, rbx                   ; Make sure we haven't hit the region's end
  jne print_loop
%endif

exit_success:
  xor edi, edi
  lea eax, [rdi+SYSCALL_EXIT]          ; Normal exit
  syscall

child:
  mov esi, r14d                   ; Restore rsi from r14 (saved earlier)
  xor eax, eax
  lea ecx, [rax+0xff]            ; Set ecx to be nonzero
  lea rdi, [r10+8]              ; Start from index 8 (past the bookkeeping)
find_work:                       ; and try to find a piece of work to claim
  cmp rax  [rdi]                 ; Check if qword [rdi] is unclaimed.
  jnz .moveon                    ; If not, move on - no use trying to lock.
  lock cmpxchg [rdi], rcx    ; Try to "claim" qword [rdi] if it is still
                                 ; unclaimed.
  jz found_work                  ; If successful, zero flag is set
.moveon:
  add rdi, 8                     ; Otherwise, try a different piece.
find_work.next:
  cmp rdi, rsi                   ; Make sure we haven't hit the end.
  jne find_work

child_exit:                      ; If we have hit the end, we're done.
  lock dec qword [r10]           ; Atomic-decrement the # of active processes.
  jmp exit_success

found_work:
  mov r8d, 8                      ; There are 8 pieces per task.
do_piece:                       ; This part does the actual work of mod-exp.
  mov r13d, r12d                   ; Copy exponent to r13d.
  mov eax, edi                   ; The actual value to mod-exp should start
  sub eax, 0x7                   ; at 1 for the first byte after the bookkeeping
  xor edx, edx                   ; word. This value is now in rax.
  div rbx                        ; Do modulo with modulus.
  mov r11, rdx                   ; Save remainder -- "modded" base -- to r11.
  xor eax, eax
  mov al, 1                     ; Initialize "result" to 1.
.modexploop:
  test r13b, 1                    ; Check low bit of exponent
  jz .shift
  mul r11                        ; If set, multiply result by base
  div rbx                        ; Modulo by modulus
  mov rax, rdx                   ; result <- remainder
.shift:
  mov r14, rax                   ; Save result to r14
  mov rax, r11                   ; and work with the base instead.
  mul rax                        ; Square the base.
  div rbx                        ; Modulo by modulus
  mov r11, rdx                   ; base <- remainder
  mov rax, r14                   ; Restore result from r14
  shr r13d, 1                     ; Shift exponent right by one bit
  jnz .modexploop                ; If the exponent isn't zero, keep working
  mov byte [rdi], al            ; Else, store result byte.
  add rdi, 1                    ; Move forward
  sub r8d, 1                    ; Decrement piece counter
  jnz do_piece                   ; Do the next piece if there is one.
  jmp find_work.next             ; Else, find the next task.

error:
  mov rdi, rax                   ; In case of error, return code is -errno...
  xor eax, eax
  mov al, SYSCALL_EXIT
  neg rdi                        ; ...so negate to get actual errno
  syscall

%ifndef NOPRINT
  extern printf
  section .data
  unsigned_int:
    db `%u\n`
%endif
