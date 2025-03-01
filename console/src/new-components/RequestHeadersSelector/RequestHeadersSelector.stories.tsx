import React from 'react';
import { ComponentMeta, Story } from '@storybook/react';
import { expect } from '@storybook/jest';
import { userEvent, within, waitFor } from '@storybook/testing-library';
import { z } from 'zod';
import {
  RequestHeadersSelector,
  RequestHeadersSelectorProps,
  requestHeadersSelectorSchema,
} from '.';
import { Button } from '../Button';
import { Form } from '../Form';

export default {
  title: 'components/Request Headers Selector',
  component: RequestHeadersSelector,
  argTypes: {
    onSubmit: { action: true },
  },
} as ComponentMeta<typeof RequestHeadersSelector>;

const schema = z.object({
  headers: requestHeadersSelectorSchema,
});

interface Props extends RequestHeadersSelectorProps {
  onSubmit: jest.Mock<void, [Record<string, unknown>]>;
}

export const Primary: Story<Props> = args => {
  return (
    <Form
      options={{
        defaultValues: {
          headers: [
            { name: 'x-hasura-role', value: 'admin', type: 'from_value' },
            { name: 'x-hasura-user', value: 'HASURA_USER', type: 'from_env' },
          ],
        },
      }}
      onSubmit={args.onSubmit}
      schema={schema}
    >
      {() => {
        return (
          <>
            <RequestHeadersSelector name={args.name} />
            <Button type="submit">Submit</Button>
          </>
        );
      }}
    </Form>
  );
};

Primary.args = {
  name: 'headers',
};

Primary.play = async ({ args, canvasElement }) => {
  const canvas = within(canvasElement);

  const addNewRowButton = canvas.getByText('Add additional header');

  // Add a third header
  await userEvent.click(addNewRowButton);
  await userEvent.type(
    canvas.getByRole('textbox', {
      name: 'headers[2].name',
    }),
    'x-hasura-name'
  );
  await userEvent.type(
    canvas.getByRole('textbox', {
      name: 'headers[2].value',
    }),
    'hasura_user'
  );

  // Add a fourth header
  await userEvent.click(addNewRowButton);
  await userEvent.type(
    canvas.getByRole('textbox', {
      name: 'headers[3].name',
    }),
    'x-hasura-id'
  );
  await userEvent.selectOptions(
    canvas.getByRole('combobox', {
      name: 'headers[3].type',
    }),
    'from_env'
  );
  await userEvent.type(
    canvas.getByRole('textbox', {
      name: 'headers[3].value',
    }),
    'HASURA_ENV_ID'
  );

  await userEvent.click(canvas.getByText('Submit'));

  const submittedHeaders: z.infer<typeof schema> = {
    headers: [
      { name: 'x-hasura-role', type: 'from_value', value: 'admin' },
      {
        name: 'x-hasura-user',
        type: 'from_env',
        value: 'HASURA_USER',
      },
      {
        name: 'x-hasura-name',
        type: 'from_value',
        value: 'hasura_user',
      },
      {
        name: 'x-hasura-id',
        type: 'from_env',
        value: 'HASURA_ENV_ID',
      },
    ],
  };

  await waitFor(() => expect(args.onSubmit).toHaveBeenCalledTimes(1));
  const firstOnSubmitCallParams = args.onSubmit.mock.calls[0];
  expect(firstOnSubmitCallParams).toMatchObject(
    expect.objectContaining([{ ...submittedHeaders }])
  );
};
