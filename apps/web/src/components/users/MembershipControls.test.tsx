import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MembershipControls } from './MembershipControls';

const { mockMutate } = vi.hoisted(() => ({ mockMutate: vi.fn() }));

vi.mock('react-i18next', () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));

vi.mock('@/hooks/queries/useUsers', () => ({
  useUpdateUserIdentity: () => ({
    mutate: mockMutate,
    isPending: false,
    error: null,
  }),
}));

describe('MembershipControls', () => {
  it('saves membership fields and presents a compact paid-through date input', async () => {
    const user = userEvent.setup();
    render(
      <MembershipControls
        serverUserId="server-user-1"
        identityName="Alice"
        identityType="normal"
        identityExpirationDate="2026-12-31"
        identityPolicy="kill_every_2_plays"
      />
    );

    expect(screen.getByLabelText('userDetail.membership.expirationDate')).toHaveClass('max-w-56');
    await user.click(screen.getByRole('button', { name: 'userDetail.membership.saveMembership' }));

    expect(mockMutate).toHaveBeenCalledWith({
      id: 'server-user-1',
      data: {
        membershipType: 'normal',
        membershipExpirationDate: '2026-12-31',
        membershipEnforcementPolicy: 'kill_every_2_plays',
      },
    });
  });
});
